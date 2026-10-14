#!/usr/bin/env python3
"""
render.py - turn an m68kdis.Analyzer result into an annotated listing.

Listing format (one line per instruction / data item):

    AAAAAAAA  HHHHHHHHHHHH....  mnemonic operands          ; comment

Data that was not reached by the flow analysis is rendered with dc.b / dc.w /
dc.l directives.  Callers supply:
  names      {addr: label}
  comments   {addr: one-line comment}          (appended to the line)
  blocks     {addr: multi-line text}           (printed above the line/label)
  data       [(start, end, kind, extra)]       explicit data regions
             kind: 'b' bytes, 'w' words, 'l' longs, 'ptr' code/data pointers,
                   'asciz' NUL-terminated strings, 'pstr' Pascal strings
                   (length byte + text), 'ascii' raw text, 'rec' records
                   (extra = format string of b/w/l letters), 'fill'
  hwname     f(addr) -> str|None              annotation of absolute addresses
"""
import re
from m68kdis import parse_abs, sext16

PC_RE = re.compile(r'\(\$([0-9a-f]+),PC\)')
ABS_RE = re.compile(r'\$([0-9a-f]+)\.([wl])')
BR_RE = re.compile(r'^\$([0-9a-f]+)$')


def printable(b):
    return 32 <= b < 127


def esc(bs):
    out = []
    for c in bs:
        if c == 0x22:
            out.append('\\"')
        elif printable(c):
            out.append(chr(c))
        else:
            out.append('\\x%02x' % c)
    return ''.join(out)


class Renderer:
    def __init__(self, rom, base, an, names, comments, blocks, data, hwname,
                 addr_width=8, code_label='sub', loc_label='loc'):
        self.rom, self.base, self.an = rom, base, an
        self.names = dict(names)
        self.comments = comments
        self.blocks = blocks
        self.data = sorted(data)
        self.hwname = hwname
        self.aw = addr_width
        self.code_label, self.loc_label = code_label, loc_label
        self.make_labels()

    # ------------------------------------------------------------ labels
    def make_labels(self):
        an = self.an
        for t, refs in an.xref.items():
            if t in self.names or t not in an.code:
                continue
            kinds = {k for _, k in refs}
            if 'c' in kinds:
                self.names[t] = f'{self.code_label}_{t:05x}'
            elif kinds == {'p'}:
                self.names[t] = f'ret_{t:05x}'
            elif 'case' in kinds:
                self.names[t] = f'case_{t:05x}'
            else:
                self.names[t] = f'{self.loc_label}_{t:05x}'
        for a, n in an.labels.items():
            if a not in self.names:
                self.names[a] = n or f'{self.code_label}_{a:05x}'
        for t in an.data_refs:
            if t not in self.names and an.inrom(t) and t not in an.code and t >= getattr(self, 'min_data_label', 0):
                self.names[t] = f'dat_{t:05x}'
        for tbl in an.case_tables:
            self.names.setdefault(tbl, f'casetbl_{tbl:05x}')
        # code entry points discovered by the heuristic pass get a label too
        for a in getattr(an, 'heuristic_entries', []):
            if a in an.code and a not in self.names:
                self.names[a] = f'{self.code_label}_{a:05x}'

    def lab(self, a):
        return self.names.get(a)

    def sym(self, a):
        n = self.names.get(a)
        return n if n else f'${a:x}'

    # ------------------------------------------------------------ operands
    def fix_ops(self, ins):
        """Replace in-ROM targets by labels; collect hardware notes."""
        ops = ins.ops
        notes = []
        base = ins.mn.split('.')[0]
        m = BR_RE.match(ops.split(',')[-1].strip()) if ops else None
        if m and (base.startswith('b') or base.startswith('db') or base.startswith('fb')) \
                and base not in ('btst', 'bset', 'bclr', 'bchg') and not base.startswith('bf'):
            t = int(m.group(1), 16)
            if t in self.names:
                ops = ops[:ops.rfind('$')] + self.names[t]

        def pcsub(mm):
            t = int(mm.group(1), 16)
            if t in self.names:
                return f'({self.names[t]},PC)'
            return mm.group(0)
        ops = PC_RE.sub(pcsub, ops)

        def abssub(mm):
            v = parse_abs(mm.group(0))
            hn = self.hwname(v) if self.hwname else None
            if hn:
                notes.append(hn)
            if self.an.inrom(v) and v in self.names and base in ('jsr', 'jmp', 'lea', 'pea'):
                return self.names[v] + ('.w' if mm.group(2) == 'w' else '')
            return mm.group(0)
        ops = ABS_RE.sub(abssub, ops)
        # immediates that are hardware addresses (movea.l #$xxxx, An / move.l #imm)
        for mm in (re.finditer(r'#\$([0-9a-f]{5,8})\b', ops) if ins.mn in ('movea.l', 'cmpa.l') else []):
            v = int(mm.group(1), 16)
            hn = self.hwname(v) if self.hwname else None
            if hn:
                notes.append('#' + hn)
        return ops, notes

    # ------------------------------------------------------------ data
    def data_kind(self, a):
        for (s, e, k, x) in self.data:
            if s <= a < e:
                return s, e, k, x
        return None

    def emit_line(self, out, a, hexb, text, comment=None):
        hx = hexb if len(hexb) <= 20 else hexb[:18] + '..'
        line = f'{a:0{self.aw}x}  {hx:<20}  {text}'
        if comment:
            line = f'{line:<70} ; {comment}'
        out.append(line.rstrip())

    def render_data(self, out, s, e, kind, extra):
        rom, b0 = self.rom, self.base
        a = s
        def boff(x):
            return x - b0
        while a < e:
            if a != s and a in self.names:
                out.append(f'{self.names[a]}:')
            if a in self.blocks and a != s:
                for bl in self.blocks[a].splitlines():
                    out.append(f'; {bl}')
            cm = self.comments.get(a)
            # stop at next label so labels stay aligned
            nxt = e
            for x in range(a + 1, e):
                if x in self.names or x in self.blocks:
                    nxt = x
                    break
            if kind in ('asciz', 'pstr', 'ascii', 'cstr'):
                if kind == 'pstr':
                    n = rom[boff(a)]
                    if a + 1 + n > nxt:
                        n = nxt - a - 1
                    bs = rom[boff(a) + 1:boff(a) + 1 + n]
                    self.emit_line(out, a, rom[boff(a):boff(a) + min(1 + n, 8)].hex(),
                                   f'dc.b    {n}, "{esc(bs)}"', cm)
                    a += 1 + n
                    continue
                if kind == 'asciz':
                    z = a
                    while z < nxt and rom[boff(z)] != 0:
                        z += 1
                    end = min(z + 1, nxt)
                else:
                    end = min(nxt, a + 48)
                bs = rom[boff(a):boff(end)]
                txt = bs[:-1] if (kind == 'asciz' and bs.endswith(b'\0')) else bs
                term = ', 0' if (kind == 'asciz' and bs.endswith(b'\0')) else ''
                self.emit_line(out, a, bs[:8].hex(), f'dc.b    "{esc(txt)}"{term}', cm)
                a = end
                continue
            if kind == 'bstr':
                idb = rom[boff(a)]
                if idb == 0:
                    self.emit_line(out, a, f'{idb:02x}', 'dc.b    $00', cm or 'end of table')
                    a += 1
                    continue
                z = a + 1
                while z < nxt and rom[boff(z)] != 0:
                    z += 1
                bs = rom[boff(a) + 1:boff(z)]
                self.emit_line(out, a, rom[boff(a):boff(a) + min(8, z + 1 - a)].hex(),
                               f'dc.b    ${idb:02x}, "{esc(bs)}", 0', cm)
                a = min(z + 1, nxt)
                continue
            if kind == 'fill':
                v = rom[boff(a)]
                self.emit_line(out, a, f'{v:02x}..', f'dcb.b   ${nxt - a:x}, ${v:02x}', cm)
                a = nxt
                continue
            if kind in ('l', 'ptr') and (a - s) % 4 == 0 and nxt - a >= 4:
                v = int.from_bytes(rom[boff(a):boff(a) + 4], 'big')
                t = f'${v:08x}'
                if kind == 'ptr' and v in self.names:
                    t = self.names[v]
                note = self.hwname(v) if (self.hwname and kind == 'ptr' and not cm) else None
                c = '; '.join(x for x in (cm, note) if x)
                self.emit_line(out, a, rom[boff(a):boff(a) + 4].hex(), f'dc.l    {t}', c or None)
                a += 4
                continue
            if kind == 'rec':
                fmt = extra
                size = sum({'b': 1, 'w': 2, 'l': 4, 'p': 4}[ch] for ch in fmt)
                if a + size > e:
                    kind = 'b'
                    continue
                p = a
                for i, ch in enumerate(fmt):
                    sz = {'b': 1, 'w': 2, 'l': 4, 'p': 4}[ch]
                    v = int.from_bytes(rom[boff(p):boff(p) + sz], 'big')
                    if ch == 'p' and v in self.names:
                        t = self.names[v]
                    else:
                        t = f'${v:0{2*sz}x}'
                    if ch == 'w':
                        t += f'  ({v})'
                    self.emit_line(out, p, rom[boff(p):boff(p) + sz].hex(),
                                   f'dc.{"l" if ch == "p" else ch}    {t}', cm if i == 0 else None)
                    p += sz
                a = p
                continue
            if kind in ('w', 'l', 'ptr') and (a & 1) == 0 and nxt - a >= 2:
                n = min(4, (nxt - a) // 2)
                ws = [int.from_bytes(rom[boff(a + 2 * i):boff(a + 2 * i) + 2], 'big') for i in range(n)]
                bs = rom[boff(a):boff(a) + 2 * n]
                asc = ''.join(chr(c) if printable(c) else '.' for c in bs)
                self.emit_line(out, a, bs.hex(),
                               'dc.w    ' + ', '.join(f'${w:04x}' for w in ws),
                               f'{cm}  |{asc}|' if cm else f'|{asc}|')
                a += 2 * n
                continue
            # bytes
            n = min(8, nxt - a)
            bs = rom[boff(a):boff(a) + n]
            asc = ''.join(chr(c) if printable(c) else '.' for c in bs)
            c = f'{asc}' if not cm else f'{cm}  |{asc}|'
            self.emit_line(out, a, bs.hex(), 'dc.b    ' + ', '.join(f'${x:02x}' for x in bs), c)
            a += n

    def auto_data_kind(self, s, e):
        """Pick a rendering for an unclaimed gap."""
        rom, b0 = self.rom, self.base
        bs = rom[s - b0:e - b0]
        if bs and all(x == bs[0] for x in bs) and len(bs) >= 8:
            return 'fill'
        if len(bs) >= 6:
            txt = sum(1 for x in bs if printable(x) or x == 0)
            runs = re.findall(rb'[ -~]{4,}', bs)
            if txt * 10 >= len(bs) * 8 and runs and sum(len(r) for r in runs) * 2 >= len(bs):
                return 'asciz'
        return 'w' if (s & 1) == 0 and (e - s) % 2 == 0 and len(bs) >= 2 else 'b'

    # ------------------------------------------------------------ main
    def render(self, lo, hi, reg_track=None):
        out = []
        an = self.an
        a = lo
        while a < hi:
            if a in self.blocks:
                out.append(';')
                for bl in self.blocks[a].splitlines():
                    out.append(f'; {bl}')
            if a in self.names:
                xr = an.xref.get(a)
                if xr:
                    froms = sorted(f for f, _ in xr)
                    xs = ', '.join(f'{f:x}' for f in froms[:6]) + (' ...' if len(froms) > 6 else '')
                    out.append(f'{self.names[a]}:{"":<{max(1, 40 - len(self.names[a]))}}; xref {xs}')
                else:
                    out.append(f'{self.names[a]}:')
            if a in an.code:
                ins = an.code[a]
                ops, notes = self.fix_ops(ins)
                if reg_track:
                    notes += reg_track(ins)
                cm = self.comments.get(a)
                c = '; '.join(x for x in ([cm] if cm else []) + notes if x)
                text = f'{ins.mn:<8}{ops}' if ops else ins.mn
                self.emit_line(out, a, ins.hexw, text, c or None)
                a += ins.size
                continue
            if a in an.case_tables:
                n, base, targets, jmpa = an.case_tables[a]
                for i, t in enumerate(targets):
                    w = int.from_bytes(self.rom[a + 2 * i - self.base:a + 2 * i + 2 - self.base], 'big')
                    self.emit_line(out, a + 2 * i, f'{w:04x}',
                                   f'dc.w    {self.sym(t)}-{self.sym(base) if base in self.names else "$%x" % base}',
                                   f'case {i}')
                a += 2 * n
                continue
            # data: find extent
            dk = self.data_kind(a)
            if dk:
                s, e, k, x = dk
                e2 = e
                for y in range(a + 1, e):
                    if y in an.code or y in an.case_tables:
                        e2 = y
                        break
                self.render_data(out, a, e2, k, x)
                a = e2
                continue
            e = a + 1
            while e < hi and e not in an.code and e not in an.case_tables and not self.data_kind(e) \
                    and e not in self.names and e not in self.blocks:
                e += 1
            self.render_data(out, a, e, self.auto_data_kind(a, e), None)
            a = e
        return out
