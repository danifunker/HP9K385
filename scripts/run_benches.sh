#!/bin/sh
# Run every unit bench in tb/ (see tb/README.md).  Outputs go to build/benches/.
#   scripts/run_benches.sh            all benches
#   scripts/run_benches.sh catseye    only benches whose name contains "catseye"
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/build/benches
mkdir -p "$OUT"
cd "$ROOT"
VFLAGS="--binary --timing -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-DECLFILENAME"

# name | simulator | sources
BENCHES="
ptm6840|iverilog|tb/tb_ptm6840.sv rtl/ptm6840.sv
catseye|verilator|tb/tb_catseye.sv rtl/catseye.sv
hp98620|iverilog|tb/tb_hp98620.sv rtl/hp98620.sv
msm58321|iverilog|tb/tb_msm58321.sv rtl/msm58321.sv
sn76494|iverilog|tb/tb_sn76494.sv rtl/sn76494.sv
uart8250|verilator|tb/tb_uart8250.sv rtl/uart8250.sv
vram_ddr3|iverilog|tb/tb_vram_ddr3.sv rtl/vram_ddr3.sv
ps2_hil_keymap|iverilog|tb/tb_ps2_hil_keymap.sv rtl/ps2_hil_keymap.sv
scsi|verilator|tb/tb_scsi.sv rtl/scsi/mb87030.sv rtl/scsi/scsi_disk.sv
wombat_bus32|verilator|tb/tb_wombat_bus32.sv rtl/wombat/wombat_bus32.sv
"

fail=0
echo "$BENCHES" | while IFS='|' read -r name sim srcs; do
	[ -z "$name" ] && continue
	case "$name" in *${1:-}*) ;; *) continue ;; esac
	log=$OUT/$name.log
	if [ "$sim" = iverilog ]; then
		iverilog -g2012 -o "$OUT/$name.vvp" $srcs > "$log" 2>&1 && vvp -n "$OUT/$name.vvp" >> "$log" 2>&1
	else
		verilator $VFLAGS --top-module "tb_$name" --Mdir "$OUT/obj_$name" -o tb $srcs > "$log" 2>&1 &&
			"$OUT/obj_$name/tb" >> "$log" 2>&1
	fi
	if grep -q "ALL TESTS PASSED\|: OK" "$log" && ! grep -q "TEST FAILED\|^FAIL" "$log"; then
		echo "pass  $name"
	else
		echo "FAIL  $name  (see $log)"
	fi
done
