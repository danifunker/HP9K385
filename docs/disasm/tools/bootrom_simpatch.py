#!/usr/bin/env python3
"""
Build a SIM-ONLY fast-boot variant of the HP 9000/380 boot ROM Rev 2.0.

    python3 -I docs/disasm/tools/bootrom_simpatch.py IN OUT [--ramsize-base 0xFF800000] [--le]

IN may be the big-endian image (bootrom_be.bin) or the MAME little-endian-word
file; OUT is written in the same byte order as IN (use --le/--be to force).
The input file is never modified.  After patching, the checksum adjust long at
0x1FFFC is recomputed so the ROM's own checksum step (19990) still passes.

Patches (addresses in the big-endian CPU view; see docs/disasm/README.md):
  0x004FA  51C8 FFFA -> 4E71 4E71   lamp test: drop the 65536-iteration delay loop
  0x0046A  7A02      -> 7A00        cold-boot flags: no RAM test (steps 400/398 skip it)
  0x02718  1038      -> 4E75        step 20: skip the 7 x 166 ms LED blink
  0x018F6  6100 375A -> 7000 4E71   step 19990: skip the 128 KB checksum loop (D0 = 0)
  optional --ramsize-base B:
  0x01C36  4DFA 000A 5988 2088 4E71 60F8 5888
        -> 207C BBBB BBBB 6006 4E71 4E71 4E71   step 1000: lowest RAM address = B, no sizing loop
"""
import sys
import argparse

PATCHES = [
    (0x004FA, '51c8fffa', '4e714e71', 'lamp test delay loop'),
    (0x0046A, '7a02', '7a00', 'cold boot: RAM test off'),
    (0x02718, '1038', '4e75', 'step 20 LED blink'),
    (0x018F6, '6100375a', '70004e71', 'step 19990 checksum loop'),
]


def sums(rom):
    d2 = d3 = 0
    for a in range(0, len(rom), 4):
        d2 += (rom[a] << 8) | rom[a + 2]
        d2 = (d2 & 0xFFFF) + (d2 >> 16)
        d3 += (rom[a + 1] << 8) | rom[a + 3]
        d3 = (d3 & 0xFFFF) + (d3 >> 16)
    return d2, d3


def fix_checksum(rom):
    rom[0x1FFFC:0x20000] = b'\0\0\0\0'
    d2, d3 = sums(rom)
    w2 = 0xFFFF - d2
    w3 = 0xFFFF - d3
    rom[0x1FFFC], rom[0x1FFFE] = w2 >> 8, w2 & 0xFF
    rom[0x1FFFD], rom[0x1FFFF] = w3 >> 8, w3 & 0xFF
    assert sums(rom) == (0xFFFF, 0xFFFF)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('inp')
    ap.add_argument('out')
    ap.add_argument('--ramsize-base', type=lambda s: int(s, 0))
    g = ap.add_mutually_exclusive_group()
    g.add_argument('--le', action='store_true', help='write MAME little-endian-word order')
    g.add_argument('--be', action='store_true', help='write big-endian order')
    a = ap.parse_args()
    raw = open(a.inp, 'rb').read()
    assert len(raw) == 0x20000
    le_in = int.from_bytes(raw[4:8], 'big') != 0x418
    rom = bytearray(raw)
    if le_in:
        rom[0::2], rom[1::2] = raw[1::2], raw[0::2]
    assert int.from_bytes(rom[4:8], 'big') == 0x418, 'not the Rev 2.0 boot ROM'
    assert sums(rom) == (0xFFFF, 0xFFFF), 'input checksum bad'
    patches = list(PATCHES)
    if a.ramsize_base is not None:
        b = a.ramsize_base & 0xFFFFFFFF
        patches.append((0x01C36, '4dfa000a59882088' '4e7160f85888',
                        '207c%08x6006' % b + '4e714e714e71', 'step 1000 RAM sizing -> fixed base'))
    for (addr, old, new, what) in patches:
        o, n = bytes.fromhex(old), bytes.fromhex(new)
        assert len(o) == len(n)
        assert rom[addr:addr + len(o)] == o, 'unexpected bytes at %05x (%s)' % (addr, what)
        rom[addr:addr + len(n)] = n
        print('patched %05x %s -> %s  (%s)' % (addr, old, new, what))
    fix_checksum(rom)
    print('checksum adjust at 0x1FFFC = %s' % rom[0x1FFFC:0x20000].hex())
    out = rom
    if (le_in and not a.be) or a.le:
        out = bytearray(len(rom))
        out[0::2], out[1::2] = rom[1::2], rom[0::2]
    open(a.out, 'wb').write(out)


if __name__ == '__main__':
    main()
