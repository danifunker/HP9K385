# Unit benches

| Bench | Status | Run |
|---|---|---|
| `tb_ptm6840.sv` | **passes** | `iverilog -g2012 -o build/tb_ptm.vvp tb/tb_ptm6840.sv rtl/ptm6840.sv && vvp -n build/tb_ptm.vvp` |
| `tb_wombat_bus32.sv` | **passes** (ported unchanged from the Quadra) | `verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-DECLFILENAME --top-module tb_wombat_bus32 --Mdir build/obj_tb_bus32 -o tb tb/tb_wombat_bus32.sv rtl/wombat/wombat_bus32.sv && build/obj_tb_bus32/tb` |
| `tb_wombat_store_buffer.sv` | **9 known failures, stale upstream** | as above, with `rtl/wombat/wombat_store_buffer.sv` |

## The store-buffer bench is stale upstream

`tb_wombat_store_buffer.sv` fails the same 9 checks (T4 pass-read and drain order) against the *unmodified* Quadra `wombat_store_buffer.sv` at the vendored revision. The bench predates later RTL changes in the Quadra tree.

The port drives the new `post_window` input with the Quadra's own address decode. Its output is **byte-identical** before and after the HP9K385 refactor (checked 2026-10-14), so the refactor is neutral.

Fix the bench, or replace it with one written against the current RTL, before relying on it.

## Catseye

| Bench | Status | Run |
|---|---|---|
| `tb_catseye.sv` | **passes**. Covers host writes and reads through PRR, overlapping window moves in all four directions, groups ending at the rectangle edge, clear, colour fill with per-plane rules, clipping with partial FB enable, and per-plane host rules. | `verilator --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_catseye --Mdir build/obj_tb_catseye -o tb tb/tb_catseye.sv rtl/catseye.sv && build/obj_tb_catseye/tb` |

The bench was mutation-checked on 2026-10-14. A swapped rule-index order and off-by-one group-edge conditions in either direction are all caught.

## MiSTer shell pieces

| Bench | Status | Run |
|---|---|---|
| `tb_vram_ddr3.sv` | **passes**. 4000 random reads and byte-enabled writes against an Avalon model with random waitrequest and read latency; checks the DDR3 bytes are in pixel order for the framebuffer. A missing byte swap is caught. | `iverilog -g2012 -o build/tb_vram.vvp tb/tb_vram_ddr3.sv rtl/vram_ddr3.sv && vvp -n build/tb_vram.vvp` |
| `tb_ps2_hil_keymap.sv` | **passes** | `iverilog -g2012 -o build/tbk.vvp tb/tb_ps2_hil_keymap.sv rtl/ps2_hil_keymap.sv && vvp -n build/tbk.vvp` |
| `tb_hp98620.sv` | **passes**: ID, device→memory and memory→device transfers in byte, word and longword units through both register sets, the interrupt level, clear-on-read, bus-error abort and general-control disarm | `iverilog -g2012 -o build/tb_dma.vvp tb/tb_hp98620.sv rtl/hp98620.sv && vvp -n build/tb_dma.vvp` |
