#!/usr/bin/env python3
"""
Generate docs/disasm/bootrom_rev2.0.asm from the big-endian boot ROM image.

    python3 -I docs/disasm/tools/gen_bootrom.py scratch/roms/hp9k380/bootrom_be.bin \
        docs/disasm/bootrom_rev2.0.asm

(bootrom_be.bin = the MAME file 1818-5062_98754_9000-380_27c210.bin with every
16-bit word byte-swapped; see docs/ROMS.md.)  If the argument is the raw MAME
file (little-endian words) it is swapped automatically: the check is that the
big-endian reset PC must be 0x418.
"""
import sys
import os
import re
import hashlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from m68kdis import Decoder, Analyzer, probe_code, is_text, sext16   # noqa: E402
from render import Renderer                                            # noqa: E402
from regtrack import RegTrack                                          # noqa: E402
import hp300map                                                        # noqa: E402
import bootrom_notes as N                                              # noqa: E402


def load(path):
    rom = open(path, 'rb').read()
    if int.from_bytes(rom[4:8], 'big') != 0x418:
        sw = bytearray(len(rom))
        sw[0::2] = rom[1::2]
        sw[1::2] = rom[0::2]
        rom = bytes(sw)
    assert int.from_bytes(rom[4:8], 'big') == 0x418, 'not the Rev 2.0 boot ROM?'
    return rom


def analyse(rom):
    d = Decoder(rom)
    an = Analyzer(d, 0, len(rom))
    an.terminal_traps = set(N.TERMINAL_TRAPS)
    an.noreturn = set(N.NORETURN)

    dmask = set()
    for (s_, e_, k_, x_) in N.DATA:
        dmask.update(range(s_, e_))

    def in_data(t):
        return t in dmask

    def hook(ins, an):
        out = []
        # pre-RAM "call" convention: lea ret(PC),A4/A6 ; bra routine ; routine ends jmp (A4)/(A6)
        # also used to set the bus-error resume address (A6) before a probe.
        m = re.fullmatch(r'\(\$([0-9a-f]+),PC\), (A[46])', ins.ops)
        if ins.mn == 'lea' and m:
            out.append((int(m.group(1), 16), None))
            an.add_xref(int(m.group(1), 16), ins.addr, 'p')
        # procedure pointers: lea proc(PC),An (any An) when the target looks like code
        if ins.mn == 'lea' and re.fullmatch(r'\(\$([0-9a-f]+),PC\), A[0-35]', ins.ops):
            t = int(ins.ops[2:ins.ops.index(',')], 16)
            if t < len(rom) and not t & 1 and not (0 < rom[t] < 80 and is_text(rom, t + 1, min(rom[t], 6))) \
                    and not is_text(rom, t, 6) and not in_data(t) and probe_code(an, t) >= 3:
                out.append((t, None))
                an.add_xref(t, ins.addr, 'p')
        # pea proc.l / lea proc.l,An with an absolute ROM address
        m = re.fullmatch(r'\$([0-9a-f]+)\.l(, A[0-6])?', ins.ops)
        if ins.mn in ('pea', 'lea') and m:
            t = int(m.group(1), 16)
            if 0x400 <= t < len(rom) and not t & 1 and not in_data(t) and not is_text(rom, t, 6) \
                    and probe_code(an, t) >= 2:
                out.append((t, None))
                an.add_xref(t, ins.addr, 'p')
        # code addresses stored to memory: move.l #proc,<mem>
        m = re.fullmatch(r'#\$([0-9a-f]+), (.*)', ins.ops)
        if ins.mn == 'move.l' and m and ('(' in m.group(2) or '$' in m.group(2)):
            t = int(m.group(1), 16)
            if 0x400 <= t < len(rom) and not t & 1 and not in_data(t) and not is_text(rom, t, 6) \
                    and probe_code(an, t) >= 2:
                out.append((t, None))
                an.add_xref(t, ins.addr, 'p')
        # HP Pascal TRY: pea recover(PC) ; move.l A7,(-$a,A5)
        m = re.fullmatch(r'\(\$([0-9a-f]+),PC\)', ins.ops)
        if ins.mn == 'pea' and m:
            t = int(m.group(1), 16)
            if t < len(rom) and not (0 < rom[t] < 80 and is_text(rom, t + 1, min(rom[t], 6))) \
                    and probe_code(an, t):
                out.append((t, None))
                an.add_xref(t, ins.addr, 'p')
        return out
    an.hooks.append(hook)

    ents = [(int.from_bytes(rom[4:8], 'big'), 'reset'), (int.from_bytes(rom[8:12], 'big'), None)]
    ents += list(N.ENTRIES)
    for a in range(0x120, 0x1EC, 4):          # fixed-address jump table
        if rom[a:a + 2] == b'\x4e\xfa':
            ents.append((a, None))
    for tbl in N.STEP_TABLES:                 # (key.w, routine.l) self-test step tables
        a = tbl
        while True:
            p = int.from_bytes(rom[a + 2:a + 6], 'big')
            if p == 0:
                break
            ents.append((p, None))
            a += 6
    for (s, e) in N.PTR_TABLES:
        for a in range(s, e, 4):
            p = int.from_bytes(rom[a:a + 4], 'big')
            if 0 < p < len(rom) and not p & 1:
                ents.append((p, None))
    an.run(ents)

    datamask = set()
    for (s, e, k, x) in N.DATA:
        datamask.update(range(s, e))

    def gaps():
        g = []
        a = 0
        while a < len(rom):
            if a in an.owner or a in datamask:
                a += 1
                continue
            b = a
            while b < len(rom) and b not in an.owner and b not in datamask:
                b += 1
            g.append((a, b))
            a = b
        return g
    an.heuristic_entries = []
    for _ in range(40):
        new = []
        for (s, e) in gaps():
            a = s + (s & 1)
            while a < e and rom[a:a + 2] in (b'\0\0', b'\xff\xff'):
                a += 2
            if a < e and not is_text(rom, a, 8) and probe_code(an, a):
                new.append((a, None))
            for x in range(a, e - 2, 2):
                if x in an.owner or x in datamask:
                    continue
                w = rom[x:x + 2]
                if w == b'\x4e\x56':
                    lk = sext16(int.from_bytes(rom[x + 2:x + 4], 'big'))
                    if lk <= 0 and lk % 2 == 0 and probe_code(an, x):
                        new.append((x, None))
                elif (w in (b'\x20\x5f', b'\x48\xe7') or rom[x - 2:x] == b'\x4e\x75') \
                        and not is_text(rom, x, 6) and probe_code(an, x) >= 4:
                    new.append((x, None))
        new = [n for n in new if n[0] not in an.code and n[0] not in datamask]
        if not new:
            break
        an.heuristic_entries += [a for a, _ in new]
        an.run(new)
    return d, an


def main():
    src, dst = sys.argv[1], sys.argv[2]
    rom = load(src)
    d, an = analyse(rom)
    ram = dict(N.RAM_NAMES)

    def hw(a):
        return hp300map.hwname(a, ram)
    names = dict(N.NAMES)
    comments = dict(N.COMMENTS)
    # exception vectors: name each vector and its RAM slot
    for v in range(0, 72):
        val = int.from_bytes(rom[4 * v:4 * v + 4], 'big')
        nm = N.VECTOR_NAMES.get(v, 'vector %d' % v)
        comments.setdefault(4 * v, 'vec %d %s' % (v, nm) + (' -> RAM JMP slot' if val >= 0xFFFF0000 else ''))
        if val >= 0xFFFF0000 and val not in ram:
            ram.setdefault(val, 'RAM JMP slot for vec %d (%s)' % (v, nm))
            ram.setdefault(val + 2, 'target of RAM JMP slot for vec %d (%s)' % (v, nm))
    for v in range(125, 256):
        comments.setdefault(4 * v, 'vec %d -> RAM JMP slot' % v)
    # self-test step tables
    for tbl in N.STEP_TABLES:
        a = tbl
        while True:
            k = int.from_bytes(rom[a:a + 2], 'big')
            p = int.from_bytes(rom[a + 2:a + 6], 'big')
            if p == 0:
                comments.setdefault(a, 'end of table')
                break
            names.setdefault(p, 'step_%d' % k)
            comments.setdefault(a, 'step %d: %s' % (k, N.STEP_DOC.get(k, '')))
            a += 6
    Renderer.min_data_label = 0x400
    r = Renderer(rom, 0, an, names, comments, N.BLOCKS, N.DATA, hw)
    for a in getattr(an, 'heuristic_entries', []):
        if a in an.code:
            r.names.setdefault(a, 'h_%05x' % a)
    rt = RegTrack(hw, r.names)
    body = r.render(0, len(rom), reg_track=rt)
    code_bytes = sum(i.size for i in an.code.values())
    hdr = [
        '; HP 9000/380 Boot ROM Rev 2.0 ("NuBOOTROM  Rev. 2.0  29 NOV 90"), HP part 1818-5062',
        '; Annotated disassembly generated by docs/disasm/tools/gen_bootrom.py (see docs/disasm/README.md)',
        '; Image: CPU (big-endian) view, mapped at 0x00000000, 128 KB.',
        ';   sha1(big-endian image)        = %s' % hashlib.sha1(rom).hexdigest(),
        ';   sha1(MAME LE-word file)       = 4c0a3929e45202a2689e353657e5c4b58ff9a1fd',
        '; Disassembler: MAME unidasm -arch m68040 (driven by a recursive-descent pass).',
        '; %d bytes classified as code (%d instructions); the rest is rendered as data.' % (code_bytes, len(an.code)),
        ';',
        '; Columns: address  opcode-bytes  instruction  ; comment',
        '; Label prefixes: sub_ = called, loc_ = branched to, case_ = switch arm, h_ = code found by',
        ';   the heuristic gap scan (no static reference found - reached through RAM vectors, pointer',
        ';   tables or computed jumps), dat_ = referenced data, casetbl_ = switch offset table.',
        '; Comment conventions: plain text = hardware name of an absolute address in the operand;',
        ';   "~addr name" = address inferred from a register loaded with a constant earlier in the',
        ';   same basic block; other comments are manual analysis (see README for verified/inferred).',
        '; Absolute short addresses $xxxx.w are sign-extended: $fed4.w = 0xFFFFFED4 (top-of-RAM globals).',
        ';',
    ]
    if an.indirect:
        pass
    with open(dst, 'w') as f:
        f.write('\n'.join(hdr + body) + '\n')
    d.close()
    print('code bytes', code_bytes, 'insns', len(an.code), 'case tables', len(an.case_tables),
          'conflicts', [hex(x) for x in an.conflicts])


if __name__ == '__main__':
    main()
