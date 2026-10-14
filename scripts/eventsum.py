#!/usr/bin/env python3
"""Fold a verilator/out/events.log into a readable probe sequence.

Bus-error runs from the same PC (a probe loop) become one line with the
address range and step; the EXC line that follows each bus error is dropped
(vector 2 is implied); ROMW lines (exception frames pushed onto the
ROM-resident reset stack) are dropped; runs of identical device polls are
counted.  PTM counter reads (delay loops) are dropped unless --ptm.

  scripts/eventsum.py [--ptm] verilator/out/events.log
"""
import re
import sys

LINE = re.compile(r'\s*(\d+) (\S+)\s+(.*)')
EV = re.compile(r'([RW]) ([0-9A-F]{8}) be=(\S) data=(\S+) fc=(\d)( walker)? pc=([0-9A-F]{8})\s*(.*)')


def main(path, show_ptm):
    out = []
    run = None   # [pc, rw, first, last, step, count, cycle, region]

    def flush():
        nonlocal run
        if run:
            pc, rw, first, last, step, n, cyc, region = run
            if n == 1:
                out.append(f'{cyc:>12} BERR {rw} {first:08X} pc={pc} {region}')
            else:
                out.append(f'{cyc:>12} BERR {rw} {first:08X}..{last:08X} step {step:X} x{n} pc={pc} {region}')
            run = None

    last_poll = None
    poll_n, poll_base = 0, ''
    emitted = False          # the previous raw line produced out[-1]
    for raw in open(path):
        m = LINE.match(raw)
        if not m:
            if 'repeated' in raw and emitted:
                n = int(re.search(r'repeated (\d+)', raw).group(1))
                out[-1] += f'  (+{n} repeats)'
            emitted = False
            continue
        emitted = False
        cyc, kind, rest = int(m.group(1)), m.group(2), m.group(3)
        if kind in ('EXC',):
            if 'vec=  2' in rest:
                continue
            flush()
            out.append(raw.rstrip())
            continue
        if kind == 'ROMW':
            continue
        if kind == 'LED':
            if not EV.match(rest):
                flush()
                out.append(f'{cyc:>12} LED  {rest.strip()}')
            continue
        e = EV.match(rest)
        if not e:
            continue
        rw, addr, be, data, fc, walker, pc, region = e.groups()
        addr = int(addr, 16)
        if kind == 'BERR':
            if run and run[0] == pc and run[1] == rw and (run[5] == 1 or addr - run[3] == run[4]):
                if run[5] == 1:
                    run[4] = addr - run[3]
                run[3] = addr
                run[5] += 1
                continue
            flush()
            run = [pc, rw, addr, addr, 0, 1, cyc, region]
            continue
        if not show_ptm and kind == 'IO8' and rw == 'R' and addr in (0x5F8008, 0x5F800C):
            continue
        flush()
        key = (kind, rw, addr, be, pc)
        if key == last_poll:
            poll_n += 1
            out[-1] = poll_base + f' x{poll_n}'
            continue
        last_poll = key
        poll_n = 1
        poll_base = f'{cyc:>12} {kind:4} {rw} {addr:08X} be={be} data={data} pc={pc} {region}'
        out.append(poll_base)
        emitted = True
    flush()
    print('\n'.join(out))


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if a != '--ptm']
    try:
        main(args[0] if args else 'verilator/out/events.log', '--ptm' in sys.argv)
    except BrokenPipeError:
        pass
