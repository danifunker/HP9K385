#!/usr/bin/env python3
"""
Per-kernel numbers from a simulator run of tools/cpubench (bench.s).

    python3 -I scripts/cpubench_report.py RUN.LOG [RUN.LOG ...]

The benchmark writes the LED latch with $10+2k before kernel k and $11+2k
after it; the simulator prints each change as
    [LED] XX  @CYCLE pc=... disp=DISPATCHES
(XX is the latch byte, or its complement, depending on the sim's LED view;
both are accepted).  For each log this prints clocks, instructions
(dispatches) and clocks per instruction per kernel.  With several logs the
columns are side by side, with the ratio of each to the first.
"""
import re
import sys

NAMES = ["ALU", "BRANCH", "MULDIV", "L1READ", "L1COPY", "STREAD", "STWRITE",
         "MEMCPY", "CHASE", "FPU", "ICACHE",
         "M16ZERO", "M16COPY"]
LED = re.compile(r"\[LED\] ([0-9A-F]{2})\s+@(\d+) .*disp=(\d+)")


def parse(path):
    marks = {}
    for line in open(path, errors="replace"):
        m = LED.search(line)
        if not m:
            continue
        v, cyc, disp = int(m.group(1), 16), int(m.group(2)), int(m.group(3))
        for code in (v, v ^ 0xFF):
            if 0x10 <= code < 0x10 + 2 * len(NAMES):
                marks[code] = (cyc, disp)
                break
    out = {}
    for k, name in enumerate(NAMES):
        a, b = marks.get(0x10 + 2 * k), marks.get(0x11 + 2 * k)
        if a and b:
            out[name] = (b[0] - a[0], b[1] - a[1])
    return out


def main():
    logs = sys.argv[1:]
    if not logs:
        sys.exit(__doc__)
    runs = [parse(p) for p in logs]
    hdr = f"{'kernel':8}"
    for p in logs:
        tag = p.rsplit("/", 1)[-1]
        hdr += f" | {tag[:28]:>28}"
    print(hdr)
    print(f"{'':8}" + " | {:>10} {:>8} {:>5}  ".format("clocks", "instr", "CPI") * len(logs))
    for name in NAMES:
        row = f"{name:8}"
        base = runs[0].get(name)
        for r in runs:
            v = r.get(name)
            if not v:
                row += " | " + f"{'-':>28}"
                continue
            clk, ins = v
            cpi = clk / ins if ins else 0
            rel = f" x{clk / base[0]:.2f}" if base and r is not runs[0] else ""
            row += f" | {clk:>10} {ins:>8} {cpi:>5.2f}{rel:>6}"
        print(row)
    for p, r in zip(logs, runs):
        tc = sum(v[0] for v in r.values())
        ti = sum(v[1] for v in r.values())
        print(f"total {p}: {tc} clocks, {ti} instructions, CPI {tc / ti if ti else 0:.2f}")


if __name__ == "__main__":
    main()
