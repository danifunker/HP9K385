#!/bin/sh
# Reference run of MAME's hp9k380 (25 MHz 68040, 98550A, 98265A SCSI in sl4)
# booting a CD image, with the 98550A's register and frame-buffer accesses
# logged (scripts/mame_vram.lua) and a snapshot at the end.
#   scripts/mame_vram.sh CD.iso [OUTDIR] [SECONDS] [TRACE_FROM_SECONDS]
# Writes OUTDIR/mame_vram.txt and OUTDIR/snap/hp9k380/*.png.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CD=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
OUT=$(mkdir -p "${2:-$ROOT/build/mame_vram}" && cd "${2:-$ROOT/build/mame_vram}" && pwd)
SECS=${3:-20}
HP385_TRACE_DIR=$OUT HP385_TRACE_FROM=${4:-0} mame hp9k380 -rompath "$ROOT/scratch/roms/zips" \
	-sl0:human_interface:ieee0 "" -cdrm "$CD" \
	-autoboot_script "$ROOT/scripts/mame_vram.lua" -autoboot_delay 0 \
	-seconds_to_run "$SECS" -video none -sound none -nothrottle -skip_gameinfo \
	-snapshot_directory "$OUT/snap" -nvram_directory "$OUT/nvram" -cfg_directory "$OUT/cfg"
echo "wrote $OUT/mame_vram.txt"
