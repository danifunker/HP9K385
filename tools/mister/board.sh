#!/usr/bin/env bash
#
# board.sh -- put the HP9K385 core on a MiSTer and look at it (ssh, key login).
#
#   board.sh push RBF     copy a build to $CORE_DIR/HP9K385.rbf (md5-checked)
#   board.sh games [DIR]  copy the SD-card files (default build/board/games/HP9K385:
#                         boot0.rom = the MAME boot ROM file as it is (word-
#                         swapped), boot1.rom = 98550a.bin, boot2.rom = the 8042
#                         1820-4784.bin, plus disk/CD images) to $GAMES; files
#                         already there with the same md5 are skipped
#   board.sh load         load_core it (cold start: the ROM downloads, then reset)
#   board.sh menu         back to the MiSTer menu
#   board.sh shot OUT.png the real HDMI output through the user's OBS
#                         (tools/mister/obs_shot.py; never the MiSTer's own
#                         screenshot command, which is too slow)
#
# Disks and the CD are mounted from the OSD (S0/S1 = SCSI IDs 0/1, S2 = the
# CD-ROM on ID 2); the stock Main_MiSTer reads a plain .iso on S2 as raw
# 2048-byte sectors, CUE/CHD need the hp9k-family Main.
#
# Environment: MISTER (default root@192.168.99.92), CORE_DIR
# (/media/fat/_Unstable), GAMES (/media/fat/games/HP9K385).
set -euo pipefail

MISTER="${MISTER:-root@192.168.99.92}"
CORE_DIR="${CORE_DIR:-/media/fat/_Unstable}"
GAMES="${GAMES:-/media/fat/games/HP9K385}"
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
rsh() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$MISTER" "$@"; }

cmd="${1:-}"; shift || true
case "$cmd" in
push)
    rbf="$1"
    rsh "mkdir -p '$CORE_DIR'"
    scp -q -o BatchMode=yes "$rbf" "$MISTER:$CORE_DIR/HP9K385.rbf"
    l=$(md5sum < "$rbf" | cut -d' ' -f1); r=$(rsh "md5sum < '$CORE_DIR/HP9K385.rbf'" | cut -d' ' -f1)
    [ "$l" = "$r" ] || { echo "md5 mismatch: $l vs $r" >&2; exit 1; }
    echo "pushed $rbf -> $CORE_DIR/HP9K385.rbf ($l)"
    ;;
games)
    dir="${1:-$root/build/board/games/HP9K385}"
    rsh "mkdir -p '$GAMES'"
    for f in "$dir"/*; do
        n=$(basename "$f")
        l=$(md5sum < "$f" | cut -d' ' -f1)
        r=$(rsh "[ -f '$GAMES/$n' ] && md5sum < '$GAMES/$n'" | cut -d' ' -f1 || true)
        if [ "$l" = "$r" ]; then echo "same     $n"; continue; fi
        scp -q -o BatchMode=yes "$f" "$MISTER:$GAMES/$n"
        r=$(rsh "md5sum < '$GAMES/$n'" | cut -d' ' -f1)
        [ "$l" = "$r" ] || { echo "md5 mismatch on $n" >&2; exit 1; }
        echo "copied   $n"
    done
    ;;
load)
    rsh "echo 'load_core $CORE_DIR/HP9K385.rbf' > /dev/MiSTer_cmd"
    echo "load_core $CORE_DIR/HP9K385.rbf"
    ;;
menu)
    rsh "echo 'load_core /media/fat/menu.rbf' > /dev/MiSTer_cmd"
    ;;
shot)
    python3 -I "$here/obs_shot.py" "$1"
    ;;
*)
    sed -n '3,22p' "$0"; exit 2 ;;
esac
