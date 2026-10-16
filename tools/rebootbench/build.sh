#!/bin/sh
# Assemble the soft-reboot test and wrap it in a bootable LIF image.
#   tools/rebootbench/build.sh IMAGE [SIZE]
# DIRTY=1 leaves card interrupts enabled before the reboot (see reboot.s).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
img=$1
size=${2:-64M}
out=$root/build/rebootbench
mkdir -p "$out"
vasmm68k_mot -quiet -Fbin -m68040 -DDIRTY="${DIRTY:-0}" -L "$out/reboot.lst" -o "$out/reboot.bin" "$here/reboot.s"
python3 -I "$root/scripts/mklif.py" -o "$img" --size "$size" --sys "SYSREBOOT:$out/reboot.bin:0xFFF00000"
