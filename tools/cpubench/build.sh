#!/bin/sh
# Assemble the CPU benchmark and wrap it in a bootable LIF image.
#   tools/cpubench/build.sh [IMAGE] [SIZE]
# Defaults: build/hp385_cpubench.img, 64M.  CACHE=0 builds it with the
# caches left off.  Needs vasmm68k_mot and python3.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
img=${1:-$root/build/hp385_cpubench.img}
size=${2:-64M}
cache=${CACHE:-1}
out=$root/build/cpubench
load=0xFFF00000          # keep in sync with LOADADDR in bench.s

mkdir -p "$out" "$(dirname "$img")"
vasmm68k_mot -quiet -Fbin -m68040 -DCACHE="$cache" -L "$out/bench.lst" \
	-o "$out/bench.bin" "$here/bench.s"
python3 -I "$root/scripts/mklif.py" -o "$img" --size "$size" \
	--sys "SYSBENCH:$out/bench.bin:$load"
