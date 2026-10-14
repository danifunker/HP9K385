#!/usr/bin/env python3
"""
m68kdis.py - small recursive-descent driver around MAME's `unidasm -arch m68040`.

unidasm only does linear sweeps.  This module asks it to decode short windows
starting at whatever address the flow analysis needs, caches every decoded
instruction by address (68k decoding at a given address is context free), and
walks the control-flow graph from a list of entry points.  Everything that is
not reached is rendered as data (strings / words / bytes) unless the caller
marks it as code.

Used by gen_bootrom.py and gen_98550a.py.  Run with `python3 -I`.
"""
import re
import subprocess
import os
import tempfile

LINE_RE = re.compile(r'^([0-9a-f]+): ((?:[0-9a-f]{4} )+) *(\S+)\s*(.*?)\s*$')

CC = ['hi', 'ls', 'cc', 'cs', 'ne', 'eq', 'vc', 'vs', 'pl', 'mi', 'ge', 'lt', 'gt', 'le',
      'hs', 'lo']
BCC = set('b' + c for c in CC)
DBCC = set('db' + c for c in CC) | {'dbra', 'dbf', 'dbt'}


def sext16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def parse_abs(tok):
    """'$1ffff.l' -> 0x1ffff ; '$fdd2.w' -> 0xfffffdd2 ; else None"""
    m = re.fullmatch(r'\$([0-9a-f]+)\.([wl])', tok)
    if not m:
        return None
    v = int(m.group(1), 16)
    if m.group(2) == 'w':
        v = sext16(v) & 0xFFFFFFFF
    return v


class Insn:
    __slots__ = ('addr', 'size', 'hexw', 'mn', 'ops')

    def __init__(self, addr, size, hexw, mn, ops):
        self.addr, self.size, self.hexw, self.mn, self.ops = addr, size, hexw, mn, ops

    @property
    def text(self):
        return f'{self.mn:<8}{self.ops}' if self.ops else self.mn


class Decoder:
    """Lazy unidasm wrapper.  `rom` is the CPU-view image, `base` its load address."""

    def __init__(self, rom, base=0, arch='m68040', window=0x400):
        self.rom = rom
        self.base = base
        self.arch = arch
        self.window = window
        self.cache = {}
        fd, self.path = tempfile.mkstemp(suffix='.bin')
        with os.fdopen(fd, 'wb') as f:
            f.write(rom)

    def close(self):
        try:
            os.unlink(self.path)
        except OSError:
            pass

    def get(self, addr):
        if addr in self.cache:
            return self.cache[addr]
        off = addr - self.base
        if off < 0 or off >= len(self.rom):
            return None
        cnt = min(self.window, len(self.rom) - off)
        out = subprocess.run(['unidasm', self.path, '-arch', self.arch,
                              '-basepc', hex(addr), '-skip', hex(off), '-count', hex(cnt)],
                             capture_output=True, text=True).stdout
        insns = []
        for ln in out.splitlines():
            m = LINE_RE.match(ln)
            if not m:
                continue
            a = int(m.group(1), 16)
            words = m.group(2).split()
            insns.append(Insn(a, 2 * len(words), ''.join(words), m.group(3), m.group(4)))
        # last few instructions may be truncated by the window end
        limit = addr + cnt - (0 if off + cnt >= len(self.rom) else 24)
        for i in insns:
            if i.addr + i.size <= limit and i.addr not in self.cache:
                self.cache[i.addr] = i
        return self.cache.get(addr)


def branch_target(ins):
    """Return (kind, target) where kind in jump/cjump/call/ret/stop/indirect/icall/none."""
    mn = ins.mn
    ops = ins.ops
    base = mn.split('.')[0]
    if base in ('rts', 'rte', 'rtr', 'rtd'):
        return 'ret', None
    if base == 'bra':
        return 'jump', int(ops.lstrip('$'), 16)
    if base == 'bsr':
        return 'call', int(ops.lstrip('$'), 16)
    if base in BCC:
        return 'cjump', int(ops.lstrip('$'), 16)
    if base in DBCC:
        t = ops.split(',')[-1].strip()
        return 'cjump', int(t.lstrip('$'), 16)
    if (base.startswith('fb') or base.startswith('pb')) and re.fullmatch(r'\$[0-9a-f]+', ops):
        return 'cjump', int(ops.lstrip('$'), 16)
    if base in ('jmp', 'jsr'):
        t = None
        m = re.fullmatch(r'\(\$([0-9a-f]+),PC\)', ops)
        if m:
            t = int(m.group(1), 16)
        else:
            t = parse_abs(ops)
        if base == 'jmp':
            return ('jump', t) if t is not None else ('indirect', None)
        return ('call', t) if t is not None else ('icall', None)
    if base in ('illegal',) or mn == 'dc.w':
        return 'bad', None
    if base == 'stop':
        return 'stop', None
    return 'none', None


class Analyzer:
    def __init__(self, dec, lo, hi):
        self.dec = dec
        self.lo, self.hi = lo, hi
        self.code = {}             # addr -> Insn (reachable)
        self.owner = {}            # byte addr -> insn addr
        self.labels = {}           # addr -> name
        self.xref = {}             # target -> set of (from, kind)
        self.entries = []          # (addr, name)
        self.indirect = []         # addrs of unresolved jmp
        self.terminal_traps = set()   # trap numbers that never return
        self.noreturn = set()         # call targets that never return
        self.case_tables = {}      # table addr -> (n, base, [targets])
        self.data_refs = {}        # addr -> set(from)
        self.conflicts = []
        self.hooks = []            # callables(ins, analyzer) -> list of extra code targets

    def inrom(self, a):
        return a is not None and self.lo <= a < self.hi

    def add_xref(self, t, frm, kind):
        self.xref.setdefault(t, set()).add((frm, kind))

    def run(self, entries):
        work = []
        for a, name in entries:
            if name and a not in self.labels:
                self.labels[a] = name
            work.append(a)
        while work:
            a = work.pop()
            while True:
                if a in self.code:
                    break
                if not self.inrom(a) or a & 1:
                    break
                if a in self.owner:     # middle of an existing instruction
                    self.conflicts.append(a)
                    break
                ins = self.dec.get(a)
                if ins is None:
                    break
                kind, t = branch_target(ins)
                if kind == 'bad':
                    self.conflicts.append(a)
                    break
                clash = any((b in self.owner) for b in range(a, a + ins.size))
                if clash:
                    self.conflicts.append(a)
                    break
                self.code[a] = ins
                for b in range(a, a + ins.size):
                    self.owner[b] = a
                for h in self.hooks:
                    for (x, nm) in h(ins, self) or []:
                        if nm and x not in self.labels:
                            self.labels[x] = nm
                        work.append(x)
                self.collect_data_refs(ins)
                nxt = a + ins.size
                if kind == 'ret' or kind == 'stop':
                    break
                if kind == 'indirect':
                    ct = self.try_case_table(ins)
                    if ct:
                        for x in ct:
                            self.add_xref(x, a, 'case')
                            work.append(x)
                    else:
                        self.indirect.append(a)
                    break
                if kind == 'icall':
                    a = nxt
                    continue
                if kind == 'jump':
                    if self.inrom(t):
                        self.add_xref(t, a, 'j')
                        a = t
                        continue
                    break
                if kind == 'cjump':
                    if self.inrom(t):
                        self.add_xref(t, a, 'b')
                        work.append(t)
                    a = nxt
                    continue
                if kind == 'call':
                    if self.inrom(t):
                        self.add_xref(t, a, 'c')
                        work.append(t)
                        if t in self.noreturn:
                            break
                    a = nxt
                    continue
                if ins.mn == 'trap':
                    n = int(ins.ops.lstrip('#$'), 16)
                    if n in self.terminal_traps:
                        break
                a = nxt

    def collect_data_refs(self, ins):
        for m in re.finditer(r'\(\$([0-9a-f]+),PC\)', ins.ops):
            t = int(m.group(1), 16)
            if ins.mn.split('.')[0] in ('jmp', 'jsr'):
                continue
            self.data_refs.setdefault(t, set()).add(ins.addr)
        for tok in re.findall(r'\$[0-9a-f]+\.[wl]', ins.ops):
            t = parse_abs(tok)
            if self.inrom(t) and ins.mn.split('.')[0] not in ('jmp', 'jsr'):
                self.data_refs.setdefault(t, set()).add(ins.addr)

    def try_case_table(self, ins):
        """HP Pascal / hand-written word offset tables:
             move.w ($6,PC,Dn.w),Dm ; jmp ($2,PC,Dm.w) ; table follows.
        unidasm prints the raw 8-bit displacement for (d8,PC,Xn) modes."""
        m = re.fullmatch(r'\(\$([0-9a-f]+),PC,(D\d)\.w\)', ins.ops)
        if not m:
            return None
        base = ins.addr + 2 + int(m.group(1), 16)
        reg = m.group(2)
        prev = self.dec.get(ins.addr - 4)
        if prev is None or not prev.mn.startswith('move.w'):
            return None
        pm = re.fullmatch(r'\(\$([0-9a-f]+),PC,(D\d)\.w\), (D\d)', prev.ops)
        if not pm or pm.group(3) != reg:
            return None
        tbl = prev.addr + 2 + int(pm.group(1), 16)
        targets = []
        lim = None
        i = 0
        while i < 512:
            pos = tbl + 2 * i
            if lim is not None and pos >= lim:
                break
            if pos in self.owner:
                break
            w = sext16(int.from_bytes(self.dec.rom[pos - self.dec.base:pos - self.dec.base + 2], 'big'))
            t = base + w
            if not self.inrom(t) or t & 1:
                break
            targets.append(t)
            if t > pos:
                lim = t if lim is None else min(lim, t)
            i += 1
        if not targets:
            return None
        self.case_tables[tbl] = (len(targets), base, targets, ins.addr)
        for b in range(tbl, tbl + 2 * len(targets)):
            self.owner.setdefault(b, -tbl)   # negative owner = data owned by table
        return targets


# ---------------------------------------------------------------- heuristics
JUNK_MN = re.compile(r'\?|^dc\.|^illegal|^[0-9]|^bkpt|^callm|^rtm|^cpsave|^cprestore|^trapv')


def is_text(rom, off, n=4):
    s = rom[off:off + n]
    if len(s) != n or not all(32 <= c < 127 for c in s):
        return False
    alnum = sum(1 for c in s if chr(c).isalnum() or c == 32)
    return alnum * 10 >= n * 7


def probe_code(an, a, max_insns=400, allow=None):
    """Linear trial decode from a.  Returns number of insns if it looks like
    code ending in a terminator, else 0."""
    dec = an.dec
    n = 0
    allow = allow or set()
    seen_bytes = 0
    while n < max_insns:
        if not an.inrom(a) or a in an.owner:
            # ran into known code: fine if we got here cleanly
            return n if n >= 2 else 0
        ins = dec.get(a)
        if ins is None:
            return 0
        base = ins.mn.split('.')[0]
        if JUNK_MN.search(ins.mn) and base not in allow:
            return 0
        kind, t = branch_target(ins)
        if kind in ('jump', 'cjump', 'call') and t is not None:
            if not an.inrom(t) or (t & 1):
                if base not in ('jsr', 'jmp'):
                    return 0
        # 'ori.b #x,D0' (0000 xxxx) is classic zero-filled data
        if ins.hexw.startswith('0000'):
            return 0
        n += 1
        if kind in ('ret', 'jump', 'indirect', 'stop'):
            return n
        if ins.mn == 'trap' and int(ins.ops.lstrip('#$'), 16) in an.terminal_traps:
            return n
        a += ins.size
    return 0
