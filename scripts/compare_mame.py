#!/usr/bin/env python3
"""Compare a Verilator boot against MAME's hp9k380 reference.

  scripts/compare_mame.py [--sim verilator/out] [--mame build/mame] [--pc N]

Three comparisons, none cycle-based (MAME runs the 040 at 25 MHz, we at 33):
  1. LED-latch sequence.
  2. Device-access sequence: every access outside ROM/RAM/VRAM/card ROM and
     the PTM, as (R/W, longword address, byte lanes), consecutive repeats
     folded.  Read *data* is not compared (MAME and the sim model different
     devices), only the order of what the ROM touches.
  3. Instruction stream (--pc N, default 2,000,000 dispatches): MAME's
     trace folds loops, so on a mismatch the sim side is skipped forward to
     resynchronise, and a taken branch (which AP68040 dispatches with pc_i
     already at its target) may be missing from the sim side; the first PC
     that cannot be resynchronised is reported.

Inputs: <sim>/events.log and <sim>/pc.log from `make -C verilator run`;
<mame>/mame_events.txt and <mame>/mame_trace.log from scripts/mame_trace.sh.
"""
import argparse
import difflib
import os
import re
import sys

SIM_EV = re.compile(r'\s*(\d+) (\S+)\s+([RW]) ([0-9A-F]{8}) be=([0-9A-F]) data=(\S+) fc=\d( walker)? pc=([0-9A-F]{8})')
SIM_LED = re.compile(r'\s*\d+ LED  ([0-9A-F]{2})$')
MAME_EV = re.compile(r'([RW]) ([0-9A-F]{8}) mask=([0-9A-F]{8}) data=([0-9A-F]{8}) pc=([0-9A-F]{8}) (\S+)')


def skip(addr):
    """Accesses left out of the device-sequence comparison."""
    return (addr < 0x20000 or 0x200000 <= addr < 0x400000 or
            0x560000 <= addr < 0x564000 or (addr >> 4) == 0x5F800 or
            addr >= 0xFF000000)


def mask_to_be(mask):
    return sum(8 >> i for i in range(4) if (mask >> (24 - 8 * i)) & 0xFF)


def fold(seq):
    out = []
    for x in seq:
        if not out or out[-1] != x:
            out.append(x)
    return out


def sim_events(path):
    leds, dev = [], []
    for line in open(path):
        m = SIM_LED.match(line.rstrip())
        if m:
            leds.append(int(m.group(1), 16))
            continue
        m = SIM_EV.match(line)
        if not m:
            continue
        kind, rw, addr, be = m.group(2), m.group(3), int(m.group(4), 16), int(m.group(5), 16)
        if kind in ('LED', 'ROMW') or skip(addr):
            continue
        dev.append((rw, addr, be))
    return leds, fold(dev)


def mame_events(path):
    leds, dev = [], []
    for line in open(path):
        m = MAME_EV.match(line)
        if not m:
            continue
        rw, addr, mask, data, _, name = m.groups()
        addr, mask, data = int(addr, 16), int(mask, 16), int(data, 16)
        if name == 'led':
            if rw == 'W' and mask & 0xFF:
                leds.append(data & 0xFF)
            continue
        if skip(addr):
            continue
        dev.append((rw, addr, mask_to_be(mask)))
    return fold(leds), fold(dev)


def fmt(e):
    return f'{e[0]} {e[1]:08X} be={e[2]:X}'


def compare_seq(name, a, b, label_a='sim', label_b='mame', context=4):
    print(f'== {name}: {label_a} {len(a)}, {label_b} {len(b)} entries')
    sm = difflib.SequenceMatcher(a=a, b=b, autojunk=False)
    shown = 0
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == 'equal':
            continue
        shown += 1
        if shown > 12:
            print('   ... more differences')
            break
        f = fmt if isinstance((a or b)[0], tuple) else (lambda x: f'{x:02X}')
        print(f'  {tag} at {label_a}[{i1}:{i2}] {label_b}[{j1}:{j2}]')
        for x in a[i1:min(i2, i1 + context)]:
            print(f'     {label_a}: {f(x)}')
        for x in b[j1:min(j2, j1 + context)]:
            print(f'     {label_b}: {f(x)}')
    if shown == 0:
        print('  identical')


def mame_pcs(path, limit):
    pcs = []
    for line in open(path):
        if len(pcs) >= limit:
            break
        if line[8:9] == ':':
            try:
                pcs.append(int(line[:8], 16))
            except ValueError:
                pass
    return pcs


def is_branch(op):
    """Bcc/BRA/BSR and DBcc opcodes."""
    return (op & 0xF000) == 0x6000 or (op & 0xF0F8) == 0x50C8


def sim_pcs(path, limit):
    """Sim dispatch PCs.  AP68040 dispatches a taken branch with pc_i
    already at its target, so that entry duplicates the next one's PC; drop
    it (the branch's own PC is then simply absent, see compare_pcs)."""
    ent = []
    for line in open(path):
        if len(ent) >= limit:
            break
        p = line.split()
        ent.append((int(p[1], 16), int(p[2], 16)))
    return [pc for k, (pc, op) in enumerate(ent)
            if not (is_branch(op) and k + 1 < len(ent) and ent[k + 1][0] == pc)]


def resync(sim, i, mame, j, window, run=16):
    """Smallest detour (di, dj) after which both streams agree for `run`
    dispatches, e.g. the two sides took different paths through an
    exception handler.  None if there is none within `window`."""
    index = {}
    for k in range(i, min(len(sim) - run, i + window)):
        index.setdefault(sim[k], []).append(k)
    for dj in range(0, window):
        jj = j + dj
        if jj + run > len(mame):
            break
        for ii in index.get(mame[jj], ()):
            if sim[ii:ii + run] == mame[jj:jj + run]:
                return ii, jj
    return None


def compare_pcs(sim, mame, window=200000, max_detours=20):
    print(f'== instruction stream: sim {len(sim)}, mame {len(mame)} (loops folded) dispatches')
    i = j = 0
    skipped = folded = detours = 0
    seen = {}
    while i < len(sim) and j < len(mame):
        if sim[i] == mame[j]:
            i += 1; j += 1
            continue
        # AP68040 dispatches a taken branch with pc_i already at its
        # target, so the branch's own PC is missing from the sim stream
        if j + 1 < len(mame) and sim[i] == mame[j + 1]:
            j += 1
            folded += 1
            continue
        # MAME folded a loop: skip the sim forward to MAME's next PC
        k = i
        lim = min(len(sim), i + window)
        while k < lim and sim[k] != mame[j]:
            k += 1
        if k < lim and sim[k:k + 3] == mame[j:j + 3]:
            skipped += k - i
            i = k
            continue
        # a real detour: report it (once per distinct pair) and resync
        key = (sim[i], mame[j])
        seen[key] = seen.get(key, 0) + 1
        r = resync(sim, i, mame, j, 2000)
        if seen[key] == 1:
            detours += 1
            print(f'  detour {detours}: sim[{i}] = {sim[i]:08X}, mame[{j}] = {mame[j]:08X}')
            print('     before : ' + ' '.join(f'{x:08X}' for x in sim[max(0, i - 6):i]))
            print('     sim    : ' + ' '.join(f'{x:08X}' for x in sim[i:i + 8]))
            print('     mame   : ' + ' '.join(f'{x:08X}' for x in mame[j:j + 8]))
            if r is not None:
                print(f'     rejoin at {sim[r[0]]:08X} after {r[0] - i} sim / {r[1] - j} mame dispatches')
        if r is None or detours >= max_detours:
            print(f'     no resync at sim[{i}] = {sim[i]:08X}, mame[{j}] = {mame[j]:08X}'
                  if r is None else '     detour limit')
            break
        i, j = r
    for (a, b), n in seen.items():
        if n > 1:
            print(f'  detour sim {a:08X} / mame {b:08X} seen {n} times')
    print(f'  compared {j} MAME dispatches: {detours} detours, {skipped} sim dispatches absorbed '
          f'by folded loops, {folded} taken branches reported at their target')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--sim', default='verilator/out')
    ap.add_argument('--mame', default='build/mame')
    ap.add_argument('--pc', type=int, default=2000000)
    args = ap.parse_args()
    sl, sd = sim_events(os.path.join(args.sim, 'events.log'))
    ml, md = mame_events(os.path.join(args.mame, 'mame_events.txt'))
    compare_seq('LED sequence', sl, ml)
    compare_seq('device accesses', sd, md)
    if args.pc:
        sp = os.path.join(args.sim, 'pc.log')
        mp = os.path.join(args.mame, 'mame_trace.log')
        if os.path.exists(sp) and os.path.exists(mp):
            compare_pcs(sim_pcs(sp, args.pc), mame_pcs(mp, args.pc))


if __name__ == '__main__':
    try:
        main()
    except BrokenPipeError:
        sys.exit(0)
