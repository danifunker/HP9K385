#!/usr/bin/env python3
"""
Generate docs/disasm/98550a.asm: an annotated listing of the HP 98550A
("Catseye" high-resolution colour) DIO card ROM.

    python3 -I docs/disasm/tools/gen_98550a.py scratch/roms/dio98550/98550a.bin docs/disasm/98550a.asm

Addressing: the file is a byte stream.  Byte n of the file appears on the bus
at 0x560000 + 2n + 1 (odd addresses; even addresses read 0xFF).  Offsets stored
*inside* the ROM are bus offsets from the card base (0x560000), so an offset
value V points at file byte (V - 1) / 2.  Multi-byte values are read with
MOVEP, i.e. from consecutive file bytes, big-endian.

There is no 68k code in this ROM (checked: the module pointer at bytes
0x42-0x43 is zero, and no region decodes as code).  It holds the ID/geometry
header, two register-initialisation tables interpreted by the boot ROM
(sub at 0x5CAC in the boot ROM), a font directory and two 10x20 fonts.
"""
import sys
import os
import hashlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hp300map  # noqa: E402

BASE = 0x560000


def bus(n):
    return BASE + 2 * n + 1


def fidx(off):
    return (off - 1) // 2


def regname(off):
    a = BASE + off
    if 0x4000 <= off < 0x5000:
        r = hp300map.catseye_reg(off - 0x4000)
        return r or 'Catseye +%x' % (off - 0x4000)
    if 0x6000 <= off < 0x6100:
        reg = (off & 0xFF) >> 1
        names = {1: 'BUSY', 0x2E: 'BLANK_ALL', 0x3C: 'WRITE_STROBE_OVERLAY', 0x50: 'UNKNOWN_A0',
                 0x51: 'OVERLAY_CTL', 0x58: 'INDEX0', 0x59: 'RED', 0x5A: 'GREEN', 0x5B: 'BLUE',
                 0x5C: 'INDEX', 0x5D: 'PLANE_MASK', 0x5E: 'OVERLAY_INDEX', 0x5F: 'REV',
                 0x78: 'WRITE_STROBE', 0x7C: 'READ_STROBE'}
        return 'Nereid reg 0x%02x %s' % (reg, names.get(reg, '(not modelled by MAME; video timing?)'))
    return hp300map.hwname(a) or '?'


HEADER = [
    # (file byte(s), name, description)
    ((0x00,), 'ID', 'DIO primary ID. 0x39: (id & 0x1F) == 0x19 = bit-mapped display, bit 6 clear'),
    ((0x01,), '-', ''),
    ((0x02, 0x03), 'FBWIDTH', 'frame-buffer width in pixels (NetBSD gr_fbwidth, bus 0x05/0x07)'),
    ((0x04, 0x05), 'FBHEIGHT', 'frame-buffer height (bus 0x09/0x0B); used by grf_clear_fb_fbheight'),
    ((0x06, 0x07), 'DWIDTH', 'displayed width (bus 0x0D/0x0F); console columns = DWIDTH / font width'),
    ((0x08, 0x09), 'DHEIGHT', 'displayed height (bus 0x11/0x13); console rows = DHEIGHT / font height'),
    ((0x0A,), 'ID2', 'secondary ID (bus 0x15).  Boot ROM: 0x0B/0x0D select table 0 directly'),
    ((0x0B,), '-', ''),
    ((0x0C,), 'BYTEPIX', 'bus 0x19 -> ($12b,A4): nonzero = one byte per pixel (FB clear uses lsr #2 not #5)'),
    ((0x0D,), '?', 'bus 0x1B'),
    ((0x0E,), '?', 'bus 0x1D'),
    ((0x0F,), '?', 'bus 0x1F'),
    ((0x10,), '?', 'bus 0x21'),
    ((0x11, 0x12), 'INITTBL0', 'bus 0x23: offset of init table 0 (register setup)'),
    ((0x13, 0x14), 'INITTBL_ALT1', 'bus 0x27: alternative table 0 (0 = use INITTBL0)'),
    ((0x15, 0x16), 'INITTBL_ALT2', 'bus 0x2B: alternative table 0 for other ID variants'),
    ((0x17, 0x18), 'INITTBL_ALT3', 'bus 0x2F'),
    ((0x19, 0x1A), 'TBL1_ENABLE', 'bus 0x33: nonzero -> run a second table after table 0'),
    ((0x1B, 0x1C), 'CTLBASE?', 'bus 0x37: 0x4000 = offset of the Catseye register block (inferred)'),
    ((0x1D, 0x1E), 'FONTDIR', 'bus 0x3B: offset of the font directory (NetBSD FONTROM)'),
    ((0x1F, 0x20), 'INITTBL1', 'bus 0x3F: offset of init table 1 (colormap)'),
    ((0x21, 0x22), 'INITTBL1_V1', 'bus 0x43: table 1 variant 1'),
    ((0x23, 0x24), 'INITTBL1_V2', 'bus 0x47: table 1 variant 2'),
    ((0x25, 0x26), 'INITTBL1_V3', 'bus 0x4B: table 1 variant 3'),
    ((0x27,), '?', 'bus 0x4F'),
    ((0x28,), '?', 'bus 0x51'),
    ((0x29,), '?', 'bus 0x53'),
    ((0x2A,), '?', 'bus 0x55'),
    ((0x2B, 0x2C), 'TBL1_SELECT', 'bus 0x57: offset of a byte whose low 2 bits pick the table-1 variant (0 = none)'),
    ((0x2D,), '?', 'bus 0x5B'),
    ((0x2E, 0x2F), 'FBADDR_PTR', 'bus 0x5D/0x5F (NetBSD gr_fbomsb/lsb): offset of the byte holding FB address bits 23:16'),
]


def decode_table(rom, k):
    """Yield (start, end, text_lines) records of an init table starting at file byte k."""
    recs = []
    while True:
        s = k
        fl = rom[k]
        lines = []
        if fl & 0x04:
            cnt = int.from_bytes(rom[k + 1:k + 5], 'big')
            off = int.from_bytes(rom[k + 5:k + 9], 'big')
            val = int.from_bytes(rom[k + 9:k + 13], 'big')
            k += 13
            lines.append('long fill: %d longs of $%08x at card+$%x (%x %s)' % (cnt + 1, val, off, BASE + off, regname(off)))
        else:
            cnt = rom[k + 1]
            off = int.from_bytes(rom[k + 2:k + 4], 'big')
            k += 4
            if fl & 0x01:
                pol, bit = rom[k], rom[k + 1] & 0xF
                k += 2
                lines.append('wait (3 s timeout) until bit %d of word at card+$%x (%s) is %s'
                             % (bit, off, regname(off), 'clear' if pol == 0 else 'set'))
            elif fl & 0x40:
                v1 = int.from_bytes(rom[k:k + 2], 'big')
                v2 = int.from_bytes(rom[k + 2:k + 4], 'big')
                k += 4
                lines.append('pair fill: %d words alternating $%04x,$%04x from card+$%x (%s)'
                             % (cnt + 1, v1, v2, off, regname(off)))
            else:
                vals = [int.from_bytes(rom[k + 2 * i:k + 2 * i + 2], 'big') for i in range(cnt + 1)]
                k += 2 * (cnt + 1)
                for i, v in enumerate(vals):
                    o = off + 2 * i
                    lines.append('write.w $%04x -> card+$%x = %x  %s' % (v, o, BASE + o, regname(o)))
        recs.append((s, k, fl, lines))
        if fl & 0x80:
            break
    return recs


def hexrow(rom, s, e):
    return rom[s:e].hex()


def emit(out, n, hx, text, comment=None):
    hx2 = hx if len(hx) <= 20 else hx[:18] + '..'
    line = '%04x %06x  %-20s  %s' % (n, bus(n), hx2, text)
    if comment:
        line = '%-78s ; %s' % (line, comment)
    out.append(line.rstrip())


def main():
    src, dst = sys.argv[1], sys.argv[2]
    rom = open(src, 'rb').read()
    assert len(rom) == 0x8000 and rom[0] == 0x39
    out = []
    chunks = []          # (sort address, lines)
    claimed = {}

    def section(addr):
        lst = []
        chunks.append((addr, len(chunks), lst))
        return lst

    def claim(s, e, what):
        for i in range(s, e):
            claimed[i] = what

    hdr = [
        '; HP 98550A high-resolution colour graphics (Catseye) - DIO card ROM, 32 KB',
        '; Annotated listing generated by docs/disasm/tools/gen_98550a.py (see docs/disasm/README.md)',
        ';   sha1 = %s (MAME dio98550 98550a.bin)' % hashlib.sha1(rom).hexdigest(),
        ';',
        '; Columns: file-offset  bus-address  bytes  directive  ; comment',
        ';   bus address of file byte n = 0x560000 + 2n + 1 (odd bytes; even bytes read 0xFF).',
        ';   Offsets stored in the ROM are bus offsets from 0x560000: value V -> file byte (V-1)/2.',
        ';   Words/longs are read with MOVEP: consecutive file bytes, big-endian.',
        ';',
        '; There is NO 68k code in this ROM: the boot ROM\'s module pointer (file bytes 0x42/0x43,',
        '; bus 0x85) is 0, and no part of the image decodes as plausible code.  The boot ROM',
        '; itself interprets the tables below (boot ROM 0x5CAC grf_card_init_tables,',
        '; 0x626E bitmap_console_init, 0x6392 grf_find_font, 0x6348 grf_fb_address).',
        ';',
        '; Checksums (verified by computation): 16-bit end-around-carry sum of big-endian words',
        ';   file 0x0000-0x1FFF = 0xFFFF (adjust word at 0x1FFE; the boot ROM checks this block,',
        ';     sub 0x5086 with D4 = 0x4000 bus bytes) and file 0x2000-0x7FFF = 0xFFFF (adjust word',
        ';     at 0x7FFE; checker not identified in the boot ROM).',
        ';',
    ]
    preamble = hdr
    out = section(0)

    # ---------------- header
    out.append(';' + '-' * 77)
    out.append('; HEADER (file 0x00-0x7F, bus 0x560001-0x5600FF)')
    out.append(';' + '-' * 77)
    for (bytes_, name, desc) in HEADER:
        s = bytes_[0]
        e = bytes_[-1] + 1
        v = int.from_bytes(rom[s:e], 'big')
        if len(bytes_) == 2:
            extra = ''
            if name in ('INITTBL0', 'FONTDIR', 'INITTBL1', 'FBADDR_PTR', 'TBL1_SELECT') and v:
                extra = ' -> file 0x%x' % fidx(v)
            if name in ('FBWIDTH', 'FBHEIGHT', 'DWIDTH', 'DHEIGHT'):
                extra = ' = %d' % v
            emit(out, s, hexrow(rom, s, e), 'dc.w    $%04x' % v, '%s: %s%s' % (name, desc, extra))
        else:
            emit(out, s, hexrow(rom, s, e), 'dc.b    $%02x' % v, ('%s: %s' % (name, desc)) if name != '-' else None)
        claim(s, e, 'hdr')
    # rest of header area up to 0x80
    fbp = int.from_bytes(rom[0x2E:0x30], 'big')
    n = 0x30
    while n < 0x80:
        if n == 0x40:
            emit(out, n, '%02x' % rom[n], 'dc.b    $%02x' % rom[n], 'bus 0x81 (meaning unknown)')
            n += 1
            continue
        if n == 0x42:
            emit(out, n, hexrow(rom, n, n + 2), 'dc.w    $%04x' % int.from_bytes(rom[n:n + 2], 'big'),
                 'MODULE: bus 0x85 offset of a RAM-loadable 68k module (boot ROM 0x8434); 0 = none')
            n += 2
            continue
        if n == fidx(fbp):
            emit(out, n, '%02x' % rom[n], 'dc.b    $%02x' % rom[n],
                 'FB address bits 23:16 (pointed to by FBADDR_PTR) -> frame buffer at 0x%06x' % (rom[n] << 16))
            n += 1
            continue
        e = n + 1
        while e < 0x80 and e not in (0x40, 0x42, fidx(fbp)) and rom[e] == rom[n] and e - n < 16:
            e += 1
        emit(out, n, hexrow(rom, n, e), 'dcb.b   %d, $%02x' % (e - n, rom[n]))
        n = e
    claim(0x30, 0x80, 'hdr')
    emit(out, 0x80, '%02x' % rom[0x80], 'dc.b    $%02x' % rom[0x80],
         'bus 0x101: DIO-II card size field, ((v >> 2) + 1) * 4 MB (boot ROM 0x177E/0x2268)')
    claim(0x80, 0x81, 'hdr')

    # ---------------- init tables
    t0 = fidx(int.from_bytes(rom[0x11:0x13], 'big'))
    t1 = fidx(int.from_bytes(rom[0x1F:0x21], 'big'))
    for title, k in (('INIT TABLE 0 (register setup), pointed to by INITTBL0', t0),
                     ('INIT TABLE 1 (colormap), pointed to by INITTBL1', t1)):
        out = section(k)
        out.append(';' + '-' * 77)
        out.append('; ' + title)
        out.append('; record: flags.b count.b offset.w data...   flags: b7 last, b6 alternating pair fill,')
        out.append(';   b2 long fill (count.l offset.l value.l), b0 wait for bit (polarity.b bit.b);')
        out.append(';   otherwise (count+1) words are written to consecutive word registers.')
        out.append(';' + '-' * 77)
        for (s, e, fl, lines) in decode_table(rom, k):
            emit(out, s, hexrow(rom, s, e), 'dc.b    ' + ', '.join('$%02x' % b for b in rom[s:min(e, s + 6)])
                 + (', ...' if e - s > 6 else ''), 'flags $%02x: %s' % (fl, lines[0]))
            for ln in lines[1:]:
                out.append('%-78s ; %s' % ('', ln))
            claim(s, e, 'tbl')

    # ---------------- font directory
    fd = fidx(int.from_bytes(rom[0x1D:0x1F], 'big'))
    cnt = rom[fd]
    out = section(fd)
    out.append(';' + '-' * 77)
    out.append('; FONT DIRECTORY (pointed to by FONTDIR): count.b, then count x (font id.b, offset.w)')
    out.append('; The boot ROM uses the entry with id 1 (grf_find_font, boot ROM 0x6392).')
    out.append(';' + '-' * 77)
    emit(out, fd, '%02x' % cnt, 'dc.b    %d' % cnt, 'number of fonts')
    fonts = []
    for i in range(cnt):
        p = fd + 1 + 3 * i
        fid = rom[p]
        off = int.from_bytes(rom[p + 1:p + 3], 'big')
        fonts.append((fid, fidx(off)))
        emit(out, p, hexrow(rom, p, p + 3), 'dc.b    %d, $%02x, $%02x' % (fid, rom[p + 1], rom[p + 2]),
             'font id %d at bus offset $%04x -> file 0x%x' % (fid, off, fidx(off)))
    claim(fd, fd + 1 + 3 * cnt, 'fontdir')

    # ---------------- fonts
    for (fid, fo) in sorted(fonts, key=lambda x: x[1]):
        h, w, b2, first, last = rom[fo], rom[fo + 1], rom[fo + 2], rom[fo + 3], rom[fo + 4]
        nglyph = last - first + 1
        gsz = 2 * h
        gbase = fo + 5
        out = section(fo)
        out.append(';' + '-' * 77)
        out.append('; FONT id %d at file 0x%x: height %d, width %d, chars 0x%02x-0x%02x (%d glyphs)'
                   % (fid, fo, h, w, first, last, nglyph))
        out.append('; header: height.b width.b ?.b first.b last.b (NetBSD: FONTHEIGHT +0, FONTWIDTH +2 bus);')
        out.append('; glyph data at header + 5 file bytes (bus +0xA = NetBSD FONTDATA): one 16-bit big-endian')
        out.append('; word per row, MSB = leftmost pixel, %d rows = %d bytes per glyph.' % (h, gsz))
        out.append(';' + '-' * 77)
        emit(out, fo, hexrow(rom, fo, fo + 5), 'dc.b    %d, %d, $%02x, $%02x, $%02x' % (h, w, b2, first, last),
             'height, width, ?, first char, last char')
        claim(fo, fo + 5, 'font')
        for g in range(nglyph):
            ch = first + g
            s = gbase + g * gsz
            label = repr(chr(ch)) if 0x20 <= ch < 0x7F else 'char 0x%02x' % ch
            out.append('; glyph 0x%02x %s' % (ch, label))
            for r in range(h):
                v = int.from_bytes(rom[s + 2 * r:s + 2 * r + 2], 'big')
                pix = format(v, '016b')[:max(w, 12)].replace('0', '.').replace('1', '#')
                emit(out, s + 2 * r, '%04x' % v, 'dc.w    $%04x' % v, pix)
            claim(s, s + gsz, 'font')

    # ---------------- checksum words
    for n in (0x1FFE, 0x7FFE):
        out = section(n)
        emit(out, n, hexrow(rom, n, n + 2), 'dc.w    $%04x' % int.from_bytes(rom[n:n + 2], 'big'),
             'checksum adjust word for block %s' % ('0x0000-0x1FFF' if n == 0x1FFE else '0x2000-0x7FFF'))
        claim(n, n + 2, 'cs')

    # ---------------- everything else: zero fill / unknown, in address order
    rest = []
    n = 0
    while n < len(rom):
        if n in claimed:
            n += 1
            continue
        e = n
        while e < len(rom) and e not in claimed:
            e += 1
        rest.append((n, e))
        n = e
    for (s, e) in rest:
        out = section(s)
        bs = rom[s:e]
        if all(b == 0 for b in bs):
            emit(out, s, '00..', 'dcb.b   $%x, $00' % (e - s), 'zero fill to file 0x%x' % e)
        else:
            for p in range(s, e, 8):
                q = min(e, p + 8)
                emit(out, p, hexrow(rom, p, q), 'dc.b    ' + ', '.join('$%02x' % b for b in rom[p:q]), 'unknown')
    final = list(preamble)
    for (_, _, lst) in sorted(chunks):
        final += lst
    with open(dst, 'w') as f:
        f.write('\n'.join(final) + '\n')
    print('fonts', fonts, 'tables', hex(t0), hex(t1), 'unclaimed', [(hex(a), hex(b)) for a, b in rest])


if __name__ == '__main__':
    main()
