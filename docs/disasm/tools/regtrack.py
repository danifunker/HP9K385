#!/usr/bin/env python3
"""Very small per-basic-block address-register constant tracker for 68k listings.

Only used to *annotate* (d16,An) style accesses whose base was loaded with a
constant a few instructions earlier (lea abs / movea.l #imm / lea (d,PC)).
State is dropped at every label and after any unconditional control transfer,
so annotations are local and conservative.  Annotations derived this way are
prefixed with '~' in the listing to mark them as inferred.
"""
import re
from m68kdis import parse_abs, sext16

SIZE = {'b': 1, 'w': 2, 'l': 4}


class RegTrack:
    def __init__(self, hwname, labels):
        self.hwname = hwname
        self.labels = labels
        self.A = {}
        self.prev_flow_end = False

    def resolve(self, ops):
        notes = []
        for m in re.finditer(r'\((?:(-?\$[0-9a-f]+),)?(A[0-6])(?:,[AD]\d\.[wl](?:\*\d)?)?\)', ops):
            r = m.group(2)
            if r not in self.A:
                continue
            d = m.group(1)
            dv = 0
            if d:
                dv = -int(d[2:], 16) if d.startswith('-') else int(d[1:], 16)
            addr = (self.A[r] + dv) & 0xFFFFFFFF
            hn = self.hwname(addr)
            if hn:
                idx = ' + index' if ',' in m.group(0)[m.group(0).find(r):] else ''
                notes.append('~%s=%x%s %s' % (r, self.A[r], idx, hn) if dv == 0 and not idx
                             else '~%x%s %s' % (addr, idx, hn))
        return notes

    def __call__(self, ins):
        if ins.addr in self.labels or self.prev_flow_end:
            self.A = {}
        self.prev_flow_end = False
        mn, ops = ins.mn, ins.ops
        base = mn.split('.')[0]
        sz = SIZE.get(mn.split('.')[-1], 2) if '.' in mn else 2
        notes = self.resolve(ops)
        # post-inc / pre-dec
        for m in re.finditer(r'\((A[0-6])\)\+', ops):
            if m.group(1) in self.A:
                self.A[m.group(1)] += sz
        for m in re.finditer(r'-\((A[0-6])\)', ops):
            if m.group(1) in self.A:
                self.A[m.group(1)] -= sz
        dst = ops.split(',')[-1].strip() if ops else ''
        if re.fullmatch(r'A[0-6]', dst):
            src = ops[:ops.rfind(',')].strip()
            v = None
            if base == 'lea':
                v = parse_abs(src)
                if v is None:
                    m = re.fullmatch(r'\(\$([0-9a-f]+),PC\)', src)
                    if m:
                        v = int(m.group(1), 16)
                m = re.fullmatch(r'\((-?)\$([0-9a-f]+),(A[0-6])\)', src)
                if m and m.group(3) in self.A:
                    d = int(m.group(2), 16) * (-1 if m.group(1) else 1)
                    v = self.A[m.group(3)] + d
            elif base == 'movea' and mn.endswith('.l'):
                m = re.fullmatch(r'#\$([0-9a-f]+)', src)
                if m:
                    v = int(m.group(1), 16)
                elif re.fullmatch(r'A[0-6]', src) and src in self.A:
                    v = self.A[src]
            elif base in ('adda', 'suba', 'addq', 'subq') and dst in self.A:
                m = re.fullmatch(r'#(-?)\$([0-9a-f]+)', src)
                if m:
                    d = int(m.group(2), 16) * (-1 if m.group(1) else 1)
                    if mn == 'adda.w':
                        d = sext16(d)
                    v = self.A[dst] + (d if base in ('adda', 'addq') else -d)
            if v is not None:
                self.A[dst] = v & 0xFFFFFFFF
            else:
                self.A.pop(dst, None)
        if base in ('exg', 'movem') and 'A' in ops.split(',')[-1]:
            self.A = {}
        if base in ('jsr', 'bsr', 'trap'):
            self.A.pop('A0', None)
            self.A.pop('A1', None)
        if base in ('bra', 'jmp', 'rts', 'rte', 'rtr', 'rtd', 'stop'):
            self.prev_flow_end = True
        return notes
