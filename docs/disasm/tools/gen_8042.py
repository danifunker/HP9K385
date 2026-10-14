#!/usr/bin/env python3
"""
Generate docs/disasm/8042_1820-4784.asm: annotated disassembly of the HP
human-interface 8042 (UPI-42, MCS-48 family) firmware 1820-4784 (2 KB).

    python3 -I docs/disasm/tools/gen_8042.py scratch/roms/human_interface/1820-4784.bin \
        docs/disasm/8042_1820-4784.asm

Uses `unidasm -arch upi41` (the UPI-41/42 variant of the MCS-48 disassembler,
which knows IN A,DBB / OUT DBB,A / MOV STS,A / EN FLAGS / JOBF / JNIBF).
Control flow is followed from the three vectors (0x000 reset, 0x003 IBF
interrupt = host wrote a byte, 0x007 timer interrupt).

Hardware wiring (from docs/reference/mame-hp380.md, MAME human_interface.cpp):
  P1      shared data bus: MLC (HP-HIL link controller), SN76494 beeper, MSM58321 RTC
  P2.0    HIL_CS (active low)
  P2.1    HIL_WE (active low) / RTC address-write strobe
  P2.2    HIL_OE (active low) / RTC write strobe
  P2.3    latch enable for the 8-bit control latch (data from P1)
  P2.4    -> host IRQ1 (with EN FLAGS this pin is the OBF interrupt output)
  P2.5    (input at reset; with EN FLAGS it is /IBF)
  P2.6    low -> host NMI (IRQ 7, keyboard reset)
  P2.7    low -> SN76494 write strobe
  latch   b7:6 MLC register select, b5 RTC read, b4 RTC CS2
  T0      /MLC interrupt;  T1 = 1
"""
import sys
import os
import re
import subprocess
import tempfile
import hashlib

LINE_RE = re.compile(r'^([0-9a-f]+): ((?:[0-9a-f]{2} ?)+?)\s{2,}(\S+)\s*(.*?)\s*$')

DATA = [
    (0x300, 0x390, 'MOVP3 lookup table (page 3): key/code translation, indexed by 0x1FE and 0x3B7'),
    (0x600, 0x606, 'MOVP lookup table (page 6): OR masks 40 10 02 (used at 0x6D0) and AND masks BF EF FD (0x6D6)'),
]

NAMES = {
    0x000: 'reset',
    0x003: 'ibf_irq',
    0x007: 'timer_irq',
    0x01D: 'cold_init',
    0x037: 'cold_init2',
    0x048: 'init_regs',
    0x05E: 'post_init',
    0x069: 'warm_start',
    0x06B: 'send_selftest_8e',
    0x074: 'host_write',
    0x093: 'host_cmd_trampoline',
    0x095: 'host_data_to_ptr',
    0x09C: 'host_data_add',
    0x0AD: 'host_data_reg9x',
    0x0E9: 'beeper_silence',
    0x100: 'host_cmd',
    0x10A: 'cmd_defer',
    0x112: 'cmd_80_ff',
    0x11D: 'cmd_c0_ff',
    0x138: 'cmd_e0_ff',
    0x141: 'cmd_f0_ff',
    0x148: 'cmd_20_3f',
    0x156: 'cmd_40_7f',
    0x161: 'cmd_88_8f',
    0x16D: 'cmd_90_9f_b0_bf',
    0x19C: 'check_warm_signature',
    0x205: 'main_loop',
    0x223: 'main_idle',
    0x28A: 'cmd_c5_mlc_trigger',
    0x2A6: 'mlc_read_r0',
    0x2AA: 'mlc_read_r1',
    0x2AE: 'mlc_read_r2',
    0x2B2: 'mlc_read_r3',
    0x2B4: 'mlc_read',
    0x2C2: 'mlc_write_r0',
    0x2C8: 'mlc_write_r1',
    0x2CE: 'mlc_write_r2',
    0x2D2: 'mlc_write',
    0x2F3: 'beeper_write',
    0x390: 'tone_start',
    0x3CD: 'cmd_c4_beeper',
    0x3E2: 'tone_timers',
    0x3FB: 'set_sig_6f',
    0x400: 'timer_tick_work',
    0x500: 'queue_put',
    0x527: 'queue_send',
    0x5BF: 'cmd_c2_rtc_write',
    0x5CC: 'cmd_c3_rtc_read',
    0x5DF: 'rtc_select',
    0x5F1: 'rtc_deselect',
    0x5FB: 'set_sig_7f',
    0x603: 'hil_poll',
    0x6F5: 'bit_mask',
    0x704: 'hil_reconfigure',
    0x72A: 'hil_loop_state',
}

COMMENTS = {
    0x000: 'read P2 inputs (bit 5 sampled at 0x022)',
    0x003: 'IBF interrupt: host wrote DBB (data at 0x420001 or command at 0x420003)',
    0x004: 'save A in bank-1 R2',
    0x007: 'timer interrupt',
    0x00B: 'RAM[0x27]++ (timer tick count, consumed by main loop)',
    0x01A: 'reload timer',
    0x01D: 'EN FLAGS: P2.4 = OBF (-> host IRQ1), P2.5 = /IBF',
    0x020: 'RAM[0x7E] = 0x1B, or 0x3B if P2.5 input was low at reset',
    0x027: 'timer = 0xCC, start',
    0x02B: 'all four SN76494 channels to max attenuation',
    0x032: 'STS = 0x70 (host sees status 0x7x; boot ROM step 4990 checks this)',
    0x06F: 'self-test / ready byte 0x8E to the host (boot ROM expects 0x8E with status 0x7x)',
    0x076: 'F1 = 1: host wrote the command register (A0 = 1)',
    0x078: 'R5 = data write pointer set by the previous command; bit7 -> 0x095',
    0x080: 'plain data byte: RAM[R5] = data (R5 auto-increments)',
    0x083: 'pointer 0x24 reached (tone pitch/duration written) -> start tone',
    0x095: 'commands 0xE0-0xEF: RAM[0x70 + n] = data (RTC register / value)',
    0x09C: 'commands 0x88-0x8F: RAM[R5] += data (with carry into the next bytes)',
    0x0E9: 'P1 = 0x20, pulse latch enable, then SN76494 writes 9F BF FF DF (silence ch 0-3)',
    0x100: 'command byte decoder',
    0x107: '0x00-0x1F: deferred command, R6 = cmd; RAM[5] |= 0x20; main loop executes it',
    0x112: '0x80-0xFF',
    0x114: '0x80-0xBF: R5 = cmd & 0x3F = data pointer for the following data bytes',
    0x11D: '0xC0-0xFF',
    0x11F: '0xC0-0xDF: dispatch on cmd & 0x1F by DJNZ chain',
    0x124: 'cmd 0xC1: R6 = 0',
    0x12A: 'cmd 0xC2: RTC write (NetBSD BBC_WRITE_REG)',
    0x12E: 'cmd 0xC3: RTC read (NetBSD BBC_READ_REG)',
    0x132: 'cmd 0xC4: beeper from RAM[0x70..0x72]',
    0x136: 'cmd 0xC5: MLC trigger (NetBSD HIL_TRIGGER)',
    0x13A: '0xE0-0xEF: R5 = 0xF0 | n (next data byte -> RAM[0x70 + n]; NetBSD BBC_SET_REG = 0xE0)',
    0x141: '0xF0-0xFF: R6 = 0x70 | n: deferred read of RAM[0x70 + n] back to the host',
    0x148: '0x20-0x3F: copy RAM[cmd-5..cmd] -> RAM[0x12..0x17]',
    0x156: '0x40-0x7F: RAM[4] = (RAM[4] & 0xE0) | (cmd & 0x1F)  (e.g. 0x5C/0x5D int on/off)',
    0x16D: '0x90-0x9F / 0xB0-0xBF',
    0x173: 'P2.6 high: release host NMI (e.g. cmd 0xB2, NetBSD HIL_CNMT)',
    0x19C: 'RAM[0x6F] == 0xAA and RAM[0x7F] == 0x55 -> warm start (RAM kept)',
    0x1AC: 'cold: clear RAM 0x01-0x7D, write the two signatures',
    0x1FE: 'MOVP3: table in page 3 (0x300 + A)',
    0x258: 'P2.6 low: assert host NMI (IRQ 7)',
    0x268: 'STS = status nibble for the byte being sent',
    0x26D: 'OUT DBB: byte to host (sets OBF -> P2.4 -> IRQ1)',
    0x27A: 'STS = 0x10',
    0x285: 'STS = 0x40',
    0x2B4: 'P1 -> latch: (reg << 6) | 0x20',
    0x2B5: 'latch enable low ...',
    0x2B7: '... high: latch captured; CS/WE/OE inactive',
    0x2B9: 'P1 as input',
    0x2BB: 'HIL_CS low',
    0x2BD: 'HIL_OE low',
    0x2BF: 'read MLC register',
    0x2D6: 'P1 = data',
    0x2D7: 'HIL_CS low',
    0x2D9: 'HIL_WE low: write MLC register',
    0x2DB: 'WE/OE high',
    0x2DD: 'CS high',
    0x2F3: 'P1 = SN76494 command byte',
    0x2F4: 'P2.7 low/high: SN76494 write strobe',
    0x3B7: 'MOVP3: table at 0x380 + n',
    0x3C4: 'SN76494: tone frequency/attenuation bytes',
    0x5C1: 'RAM[0x70]: high nibble = data, low nibble = RTC register',
    0x5C3: 'P1 = data nibble',
    0x5C4: 'P2.2 pulse: RTC write strobe',
    0x5CE: 'P1 input',
    0x5D0: 'latch strobe (P1 = 0xFF -> latch: RTC read enabled)',
    0x5D4: 'R6 = 0x70: deferred "send RAM[0x70]" to the host',
    0x5D6: 'read RTC data nibble (read twice)',
    0x5DF: 'R0 -> RAM[0x70]; latch = 0x10 (RTC CS2)',
    0x5E1: 'latch enable low, WE/OE low',
    0x5E8: 'latch enable high + CS',
    0x5EB: 'P1 = RTC register address',
    0x5EC: 'P2.1 pulse: RTC address write',
    0x5F1: 'latch = 0x20 (RTC deselected), P1 = 0xFF',
    0x6D0: 'MOVP: table in page 6',
    0x6F1: 'P2.6 low: assert host NMI (keyboard reset sequence)',
}


def decode_all(rom):
    fd, path = tempfile.mkstemp(suffix='.bin')
    with os.fdopen(fd, 'wb') as f:
        f.write(rom)
    cache = {}
    try:
        def get(a):
            if a in cache:
                return cache[a]
            cnt = min(0x40, len(rom) - a)
            out = subprocess.run(['unidasm', path, '-arch', 'upi41', '-basepc', hex(a), '-skip', hex(a),
                                  '-count', hex(cnt)], capture_output=True, text=True).stdout
            lim = a + cnt - (0 if a + cnt >= len(rom) else 3)
            for ln in out.splitlines():
                m = LINE_RE.match(ln)
                if not m:
                    continue
                x = int(m.group(1), 16)
                bs = bytes.fromhex(m.group(2).replace(' ', ''))
                if x + len(bs) <= lim and x not in cache:
                    cache[x] = (len(bs), bs, m.group(3), m.group(4))
            return cache.get(a)
        return get
    finally:
        pass


def flow(mn, ops):
    if mn in ('ret', 'retr'):
        return 'ret', None
    if mn == 'jmp':
        return 'jump', int(ops.lstrip('$'), 16)
    if mn == 'call':
        return 'call', int(ops.lstrip('$'), 16)
    if mn == 'jmpp':
        return 'indirect', None
    if mn == 'djnz' or (mn.startswith('j') and mn not in ('jmp', 'jmpp')):
        t = ops.split(',')[-1].strip()
        return 'cjump', int(t.lstrip('$'), 16)
    if mn == 'illegal':
        return 'bad', None
    return 'none', None


def main():
    src, dst = sys.argv[1], sys.argv[2]
    rom = open(src, 'rb').read()
    assert len(rom) == 0x800
    get = decode_all(rom)
    datamask = set()
    for s, e, _ in DATA:
        datamask.update(range(s, e))
    code = {}
    owner = {}
    xref = {}
    work = [0x000, 0x003, 0x007]
    bad = []
    while work:
        a = work.pop()
        while 0 <= a < len(rom) and a not in code:
            if a in owner or a in datamask:
                bad.append(a)
                break
            d = get(a)
            if d is None:
                break
            size, bs, mn, ops = d
            k, t = flow(mn, ops)
            if k == 'bad':
                bad.append(a)
                break
            code[a] = d
            for b in range(a, a + size):
                owner[b] = a
            nxt = a + size
            if t is not None:
                xref.setdefault(t, set()).add((a, k))
            if k == 'ret' or k == 'indirect':
                break
            if k == 'jump':
                a = t
                continue
            if k in ('cjump', 'call'):
                work.append(t)
            a = nxt
    names = dict(NAMES)
    for t, refs in xref.items():
        if t in names:
            continue
        kinds = {k for _, k in refs}
        names[t] = ('sub_%03x' if 'call' in kinds else 'l_%03x') % t

    def sym(t):
        return names.get(t, '$%03X' % t)

    out = [
        '; HP human-interface 8042 (UPI-42) firmware, HP part 1820-4784, 2 KB',
        '; Annotated disassembly generated by docs/disasm/tools/gen_8042.py (see docs/disasm/README.md)',
        ';   sha1 = %s (MAME human_interface 1820-4784.bin)' % hashlib.sha1(rom).hexdigest(),
        '; Disassembler: MAME unidasm -arch upi41, recursive descent from the reset/IBF/timer vectors.',
        '; %d bytes reached as code; the rest is data or unreached filler.' % len(owner),
        ';',
    ]
    out += ['; ' + l for l in __doc__.strip().splitlines()[9:]]
    out.append(';')
    out.append('; Bank-0 registers in the main code (inferred): R2 = state flags, R3 = scratch/argument,')
    out.append(';   R4/R5/R6 = flag bytes (R5 also = host data write pointer, R6 = deferred command),')
    out.append(';   R7 = misc.  Bank 1 is used by the interrupt handlers (R2 = saved A).')
    out.append(';')
    a = 0
    while a < len(rom):
        if a in names and (a in code or a in xref):
            xr = xref.get(a)
            xs = (' ; xref ' + ', '.join('%03x' % f for f, _ in sorted(xr))) if xr else ''
            out.append('%s:%s' % (names[a], xs))
        if a in code:
            size, bs, mn, ops = code[a]
            k, t = flow(mn, ops)
            o = ops
            if t is not None and t in names:
                o = re.sub(r'\$[0-9A-Fa-f]{3}$', sym(t), ops)
            line = '%03x  %-6s  %-6s %s' % (a, bs.hex(' '), mn, o)
            c = COMMENTS.get(a)
            if c:
                line = '%-44s ; %s' % (line, c)
            out.append(line.rstrip())
            a += size
            continue
        # data
        dd = [x for x in DATA if x[0] <= a < x[1]]
        if dd:
            s, e, desc = dd[0]
            if a == s:
                out.append('; ' + desc)
            q = min(e, a + 8)
            out.append('%03x  %-24s dc.b   %s' % (a, rom[a:q].hex(' '), ', '.join('$%02X' % b for b in rom[a:q])))
            a = q
            continue
        e = a
        while e < len(rom) and e not in code and not any(x[0] <= e < x[1] for x in DATA) and e - a < 8:
            e += 1
        note = 'unreached'
        if all(b == 0 for b in rom[a:e]):
            note = 'unreached (NOP filler)'
        out.append('%-44s ; %s' % ('%03x  %-24s dc.b   %s' % (a, rom[a:e].hex(' '), ', '.join('$%02X' % b for b in rom[a:e])), note))
        a = e
    with open(dst, 'w') as f:
        f.write('\n'.join(out) + '\n')
    print('code bytes', len(owner), 'bad', [hex(x) for x in bad])


if __name__ == '__main__':
    main()
