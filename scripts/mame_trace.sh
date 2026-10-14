#!/bin/sh
# Capture a reference boot of MAME's hp9k380 (25 MHz 68040, 98550A in sl1,
# no other DIO cards, no HP-IB disk) for comparison with the Verilator sim.
#   scripts/mame_trace.sh [OUTDIR] [SECONDS]
# Writes OUTDIR/mame_events.txt (bus accesses, see mame_trace.lua) and
# OUTDIR/mame_trace.log (debugger instruction trace, loops folded).
# ROM zips (hp9k380, dio98550, human_interface) are read from scratch/roms/zips.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(mkdir -p "${1:-$ROOT/build/mame}" && cd "${1:-$ROOT/build/mame}" && pwd)
SECS=${2:-4}
HP385_TRACE_DIR=$OUT mame hp9k380 -rompath "$ROOT/scratch/roms/zips" \
	-sl0:human_interface:ieee0 "" -sl2 "" -sl3 "" -sl4 "" \
	-debug -debugger none -autoboot_script "$ROOT/scripts/mame_trace.lua" -autoboot_delay 0 \
	-seconds_to_run "$SECS" -video none -sound none -nothrottle -skip_gameinfo \
	-nvram_directory "$OUT/nvram" -cfg_directory "$OUT/cfg"
echo "wrote $OUT/mame_events.txt $OUT/mame_trace.log"
