#!/bin/sh
# Assemble the boot test program and wrap it in a bootable LIF image.
#   tools/bootblk/build.sh [IMAGE] [SIZE]
# Defaults: build/hp385_testboot.img, 64M.  Needs vasmm68k_mot and python3.
# TAILTEST=0 tools/bootblk/build.sh builds the small one-sector variant
# (loaded by programmed I/O only, no DMA); see test.s.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
img=${1:-$root/build/hp385_testboot.img}
size=${2:-64M}
tail=${TAILTEST:-1}
out=$root/build/bootblk
load=0xFFF00000          # keep in sync with LOADADDR in test.s

mkdir -p "$out" "$(dirname "$img")"
vasmm68k_mot -quiet -Fbin -m68040 -DTAILTEST="$tail" -L "$out/test.lst" \
	-o "$out/test.bin" "$here/test.s"
python3 -I "$root/scripts/mklif.py" -o "$img" --size "$size" \
	--sys "SYSTEST:$out/test.bin:$load"
