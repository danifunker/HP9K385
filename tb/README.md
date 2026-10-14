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
