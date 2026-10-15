#!/bin/sh
# Pre-build gate: full-system sim checks to run before every Quartus build
# (a bitstream costs ~40 minutes and board time; these take ~10).
#   scripts/prebuild_gate.sh
# 1. the unit benches (scripts/run_benches.sh);
# 2. the boot ROM boots tools/cpubench from a SCSI disk on ID 0 and the
#    benchmark finishes (stop at its final loop, LED F0): ROM self-tests,
#    the SCSI card's register test, DMA disk reads, the CPU and the console;
# 3. with a CD on ID 2 as well (if scratch/sw/OpenBSD55 is there), the ROM
#    finds and boots the CD.
# Uses the fast selection time-out sim build (obj_fast).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
V=$ROOT/verilator
OUT=$ROOT/build/gate
mkdir -p "$OUT"
fail=0

echo "== unit benches"
sh "$ROOT/scripts/run_benches.sh" | tee "$OUT/benches.txt"
grep -q FAIL "$OUT/benches.txt" && fail=1

echo "== sim build"
(cd "$V" && make MDIR=obj_fast V_DEFS=+define+SIM_FAST_SELTO -j6 > "$OUT/build.log" 2>&1) || { echo "FAIL sim build"; exit 1; }
[ -f "$V/out/bootrom_fast.bin" ] || (cd "$V" && make out/bootrom_fast.bin > /dev/null)
"$ROOT/tools/cpubench/build.sh" "$OUT/bench.img" > /dev/null
stop=$(grep "\.done:" "$ROOT/build/cpubench/bench.lst" | awk '{print substr($1,4)}')
SIM="$V/obj_fast/Vhp385_top --rom $V/out/bootrom_fast.bin --card-rom $ROOT/scratch/roms/dio98550/98550a.bin --hil-rom $ROOT/scratch/roms/human_interface/1820-4784.bin --loop-window 0 --log /dev/null"

echo "== disk boot (ID 0): cpubench to its end at $stop"
$SIM --disk0 "$OUT/bench.img" --cycles 160000000 --stop-pc "$stop" --snap "$OUT/disk.ppm" > "$OUT/disk.log" 2>&1
if grep -a -q "stop: stop-pc" "$OUT/disk.log" && grep -a -q "leds=F0" "$OUT/disk.log"; then
	echo "pass  disk boot"
else
	echo "FAIL  disk boot (see $OUT/disk.log, $OUT/disk.ppm)"; fail=1
fi

CD=$ROOT/scratch/sw/OpenBSD55/x/CD_BOOT.iso
if [ -f "$CD" ]; then
	echo "== CD boot (ID 2) with the disk on ID 0"
	"$ROOT/tools/cpubench/build.sh" "$OUT/bench2.img" > /dev/null
	$SIM --disk0 "$OUT/bench2.img" --cd "$CD" --cycles 70000000 > "$OUT/cd.log" 2>&1
	if [ "$(grep -a -c 'DISK2. read' "$OUT/cd.log")" -ge 20 ]; then echo "pass  CD boot"
	else echo "FAIL  CD boot (see $OUT/cd.log)"; fail=1; fi
fi

[ $fail -eq 0 ] && echo "GATE: PASS" || { echo "GATE: FAIL"; exit 1; }
