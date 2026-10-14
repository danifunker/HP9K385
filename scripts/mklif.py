#!/usr/bin/env python3
"""Build a LIF volume image that the HP 9000/300 Boot ROM (Rev 2.0) can boot.

The format is what the ROM's LIF loader checks and uses (see
docs/reference/lif_boot.md for the ROM addresses):

  * LIF sectors are 256 bytes.  Sector numbers in the volume header and the
    directory count 256-byte sectors from the start of the volume (the ROM's
    SCSI driver turns them into 512-byte block reads).
  * Volume header at sector 0.  The ROM requires
        +0x00 0x8000 (LIF id)   +0x0C 0x1000   +0x0E 0   +0x16 0
    and takes the directory start from +0x08 and its length (sectors)
    from +0x10.
  * Directory: 32-byte entries, 8 per sector.  type 0xFFFF ends the
    directory, type 0 is a purged entry.  A bootable system is type 0xE942
    (-5822) whose name starts with "SYS"; the ROM lists it under the letter
    of the first character where the name differs from "SYSTEM_" (e.g.
    SYSHPUX -> "H", SYSNBSD -> "N", SYSTEM_A -> "A").
        +0x00 name[10] (space padded)   +0x0A type   +0x0C start sector
        +0x10 length (sectors)          +0x14 date (6 BCD bytes)
        +0x1A 0x8001 (last-volume flag) +0x1C entry (execution) address
  * A system file is a list of load records, each starting on a sector
    boundary: {load address.l, byte count.l, data[count]}.  The first 248
    data bytes share the sector with the 8-byte header; the rest follows
    from the next sector on.  The ROM walks records while a whole sector is
    left in the file, then jumps to the directory entry's entry address.

Usage:
  scripts/mklif.py -o IMAGE [--size SIZE] [--label LABEL] [--dir-sectors N]
                   [--sys NAME:BINARY:LOAD[:ENTRY]] ...
                   [--file NAME:PATH[:TYPE]] ...

  --sys   adds a bootable system: BINARY is raw (no header); it is loaded at
          LOAD and entered at ENTRY (default LOAD).  NAME must start with SYS
          and is at most 10 characters (A-Z, 0-9, _).
  --file  adds a plain file copied as-is, TYPE as a number (default 1).
  --size  image size in bytes, with an optional K/M/G suffix (default 16M).
          The image is written sparse.

Example:
  scripts/mklif.py -o build/hp385_testboot.img --size 64M \\
      --sys SYSTEST:build/bootblk/test.bin:0xFFF00000

Run with python3 -I.  Dates are taken from SOURCE_DATE_EPOCH if set, so
images can be reproducible; otherwise the current time is used.
"""
import argparse
import os
import struct
import sys
import time

SECT = 256
DIR_START = 2           # sector 2 = byte 512 (NetBSD mkboot LIF_DIRSTART)
FILE_START = 32         # sector 32 = byte 8192 (NetBSD mkboot LIF_FILESTART)
TYPE_SYS = 0xE942       # -5822, HP-UX/BOOT system file
TYPE_END = 0xFFFF
HDR_DATA = SECT - 8     # data bytes in the first sector of a load record


def parse_size(s):
    mult = {'K': 1 << 10, 'M': 1 << 20, 'G': 1 << 30}
    s = s.strip().upper()
    if s and s[-1] in mult:
        return int(s[:-1], 0) * mult[s[-1]]
    return int(s, 0)


def bcd(n):
    return ((n // 10) << 4) | (n % 10)


def lif_date():
    t = os.environ.get('SOURCE_DATE_EPOCH')
    tm = time.gmtime(int(t) if t else None)
    return bytes(bcd(v) for v in (tm.tm_year % 100, tm.tm_mon, tm.tm_mday,
                                  tm.tm_hour, tm.tm_min, tm.tm_sec))


def lif_name(name):
    name = name.upper()
    if not 1 <= len(name) <= 10:
        sys.exit(f'mklif: name {name!r} must be 1-10 characters')
    if not all(c.isalnum() or c == '_' for c in name):
        sys.exit(f'mklif: name {name!r}: use A-Z, 0-9 and _ only')
    return name.encode('ascii').ljust(10, b' ')


def sectors(nbytes):
    return (nbytes + SECT - 1) // SECT


def system_payload(data, load):
    """One load record: header + data, padded so the record fills whole
    sectors and the part after the first sector is a multiple of 256 (the
    ROM reads that part with one device read; padding keeps it sector-sized).
    Returns the file contents."""
    count = len(data)
    if count > HDR_DATA:
        count = HDR_DATA + sectors(count - HDR_DATA) * SECT
    data = data.ljust(count, b'\0')
    rec = struct.pack('>II', load, count) + data
    return rec.ljust(sectors(len(rec)) * SECT, b'\0')


def build(args):
    size = parse_size(args.size)
    if size % 512:
        sys.exit('mklif: --size must be a multiple of 512')
    total = size // SECT
    date = lif_date()

    files = []   # (name10, type, payload, entry)
    for spec in args.sys or []:
        parts = spec.split(':')
        if len(parts) not in (3, 4):
            sys.exit(f'mklif: --sys {spec!r}: want NAME:BINARY:LOAD[:ENTRY]')
        name, path, load = parts[0], parts[1], int(parts[2], 0)
        entry = int(parts[3], 0) if len(parts) == 4 else load
        if not name.upper().startswith('SYS'):
            print(f'mklif: warning: {name} does not start with SYS; the ROM '
                  'will not list it', file=sys.stderr)
        with open(path, 'rb') as f:
            data = f.read()
        if load & 1 or entry & 1:
            sys.exit('mklif: load and entry addresses must be even')
        files.append((lif_name(name), TYPE_SYS, system_payload(data, load), entry))
    for spec in args.file or []:
        parts = spec.split(':')
        if len(parts) not in (2, 3):
            sys.exit(f'mklif: --file {spec!r}: want NAME:PATH[:TYPE]')
        ftype = int(parts[2], 0) & 0xFFFF if len(parts) == 3 else 1
        if ftype in (0, TYPE_END):
            sys.exit('mklif: file type 0 and 0xFFFF are reserved')
        with open(parts[1], 'rb') as f:
            data = f.read()
        files.append((lif_name(parts[0]), ftype, data.ljust(sectors(len(data)) * SECT, b'\0'), 0))
    if not files:
        sys.exit('mklif: nothing to put on the volume (use --sys/--file)')

    dir_sectors = args.dir_sectors or max(1, sectors((len(files) + 1) * 32))
    if len(files) > dir_sectors * 8:
        sys.exit('mklif: directory too small')
    first = max(FILE_START, DIR_START + dir_sectors)
    first += first & 1              # 512-byte block aligned

    img = bytearray()
    dir_ents = []
    sect = first
    blobs = []
    for name, ftype, payload, entry in files:
        n = len(payload) // SECT
        flag = 0x8001
        dir_ents.append(name + struct.pack('>HII', ftype, sect, n) + date +
                        struct.pack('>HI', flag, entry))
        blobs.append((sect, payload))
        sect += n
        sect += sect & 1            # next file on a 512-byte boundary
    if sect > total:
        sys.exit(f'mklif: files need {sect} sectors, image has {total}')
    # unused entries: end-of-directory markers
    while len(dir_ents) < dir_sectors * 8:
        dir_ents.append(b' ' * 10 + struct.pack('>HII', TYPE_END, 0, 0) +
                        bytes(6) + struct.pack('>HI', 0, 0))

    # volume header (standard LIF layout; the ROM checks only the first
    # 0x18 bytes).  tracks/surfaces/sectors-per-track describe the volume
    # as one surface of 256-sector tracks.
    label = args.label.upper().encode('ascii')[:6].ljust(6, b' ')
    spt = 256 if total % 256 == 0 else 1
    vol = struct.pack('>H6sIHHIHHIII', 0x8000, label, DIR_START, 0x1000, 0,
                      dir_sectors, 1, 0, total // spt, 1, spt) + date
    vol = vol.ljust(SECT, b'\0')

    with open(args.output, 'wb') as f:
        f.write(vol)
        f.seek(DIR_START * SECT)
        f.write(b''.join(dir_ents))
        for s, payload in blobs:
            f.seek(s * SECT)
            f.write(payload)
        f.truncate(size)

    if not args.quiet:
        print(f'{args.output}: {size} bytes, {total} LIF sectors, directory at '
              f'sector {DIR_START} ({dir_sectors} sectors)')
        for (name, ftype, payload, entry), (s, _) in zip(files, blobs):
            extra = ''
            if ftype == TYPE_SYS:
                load, count = struct.unpack('>II', payload[:8])
                extra = f' load {load:08X} count {count:#x} entry {entry:08X}'
            print(f'  {name.decode().rstrip():10} type {ftype:04X} sector {s} '
                  f'(block {s // 2}) length {len(payload) // SECT}{extra}')


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('-o', '--output', required=True)
    ap.add_argument('--size', default='16M')
    ap.add_argument('--label', default='HP385')
    ap.add_argument('--dir-sectors', type=int, default=0,
                    help='directory length in sectors (default: just enough)')
    ap.add_argument('--sys', action='append', metavar='NAME:BINARY:LOAD[:ENTRY]')
    ap.add_argument('--file', action='append', metavar='NAME:PATH[:TYPE]')
    ap.add_argument('-q', '--quiet', action='store_true')
    build(ap.parse_args())


if __name__ == '__main__':
    main()
