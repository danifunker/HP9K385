#!/bin/sh
# Boot an OS image on MAME's hp9k380 (25 MHz 68040, 98550A, 98265A SCSI in
# sl4) as a reference for the core, with a snapshot every SNAP seconds of
# emulated time (scripts/mame_os.lua).
#   scripts/mame_os.sh OUTDIR SECONDS [-cdrm CD.iso] [-hard DISK.hd] [other MAME options]
#   SNAP=30 scripts/mame_os.sh build/mame_os/hpux9 600 -cdrm scratch/sw/HPUX910/x/...iso
# Snapshots land in OUTDIR/snap/hp9k380/NNNN.png, in time order.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(mkdir -p "$1" && cd "$1" && pwd)
SECS=$2
shift 2
HP385_SNAP_EVERY=${SNAP:-60} mame hp9k380 -rompath "$ROOT/scratch/roms/zips" \
	-sl0:human_interface:ieee0 "" "$@" \
	-autoboot_script "$ROOT/scripts/mame_os.lua" -autoboot_delay 0 \
	-seconds_to_run "$SECS" -video none -sound none -nothrottle -skip_gameinfo \
	-snapshot_directory "$OUT/snap" -nvram_directory "$OUT/nvram" -cfg_directory "$OUT/cfg"
ls "$OUT/snap/hp9k380"
