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
| `tb_upi41_diff.sv` | **passes**. Lockstep differential test of `rtl/upi41.sv` (data RAM in one M10K) against `tb/upi41_ref.sv` (the original register-file core). Both run the real HIL firmware, or random programs with `+randrom`, with random ticks, resets and host traffic. Ports and sequencer state are compared every clock and the full RAM every 4096 clocks. Needs the 8042 ROM in `scratch/`. 12 mutations were checked; all are caught. | `verilator --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_upi41_diff --Mdir build/obj_tb_upi41 -o tb tb/tb_upi41_diff.sv tb/upi41_ref.sv rtl/upi41.sv && build/obj_tb_upi41/tb [+cycles=N] [+seed=S] [+randrom]` |
| `tb_ps2_hil_keymap.sv` | **passes** | `iverilog -g2012 -o build/tbk.vvp tb/tb_ps2_hil_keymap.sv rtl/ps2_hil_keymap.sv && vvp -n build/tbk.vvp` |
| `tb_hp98620.sv` | **passes**: ID, device→memory and memory→device transfers in byte, word and longword units through both register sets, the interrupt level, clear-on-read, bus-error abort and general-control disarm | `iverilog -g2012 -o build/tb_dma.vvp tb/tb_hp98620.sv rtl/hp98620.sv && vvp -n build/tb_dma.vvp` |
| `tb_msm58321.sv` | **passes**: set from the MiSTer RTC, year end, leap and non-leap February, 30-day month, 12-hour midnight, register reads and writes | `iverilog -g2012 -o build/tb_rtc.vvp tb/tb_msm58321.sv rtl/msm58321.sv && vvp -n build/tb_rtc.vvp` |
| `tb_sn76494.sv` | **passes**: tone frequency at the HP clock (f = 333,333/(4N)) and silence at attenuation 15 | `iverilog -g2012 -o build/tb_snd.vvp tb/tb_sn76494.sv rtl/sn76494.sv && vvp -n build/tb_snd.vvp` |

## SCSI

| Bench | Status | Run |
|---|---|---|
| `tb_scsi.sv` | **passes**. One MB87030 and one `scsi_target` with four units (disks on IDs 0 and 1, a CD-ROM on ID 2, ID 3 without an image) on an ORed bus, each unit with an hps_io-timed block model on a shared `sd_buff_*` bus. Covers selection with ATN and IDENTIFY, INQUIRY, TEST UNIT READY, READ CAPACITY, DMA READ and WRITE(10), READ(6), MODE SENSE, sense paths, NOT READY on the empty disk, the CD-ROM (unit attention, 512/2048 blocks, READ TOC/MSF), commands alternating between units with image, sense, read-only, unit attention and block length kept per unit, SCSI RST with a block request pending, and selection timeout. 15 mutations of the shared engine were checked; all are caught (see `docs/reference/scsi.md`). | `verilator --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_scsi --Mdir build/obj_tb_scsi -o tb tb/tb_scsi.sv rtl/scsi/mb87030.sv rtl/scsi/scsi_target.sv && build/obj_tb_scsi/tb` |
| `tb_scsi_dma.sv` | **passes**. The whole card (`hp98265a`) with the 98620 (`hp98620`) and a memory model, driven like the boot ROM (a READ(10) by DMA on channel 0, polled) and then like NetBSD 9 (`spc_dio_attach`/`spc_init`, then the probe of IDs 0-2: TEST UNIT READY, REQUEST SENSE by NetBSD's exact PIO loop, a 36-byte INQUIRY by longword DMA on channel 1 with STATUS/MESSAGE IN read from TEMP). Also covers HP-UX's RST release by SCTL = 0xC0, and a fast CPU on REQUEST SENSE. Each of the three fixes it was written for fails the bench when reverted:
- the 98620 took the first byte of a DMA read after a channel change as $FF (NetBSD's `scsipi_dtype` panic, OpenBSD's "31/vendor-unique");
- the SPC pushed a received byte before ACK, so NetBSD saw REQ still up after the last byte;
- RST stayed on the bus through SCTL[7]. Uses `tb_blkdev` from `tb_scsi.sv`. | `verilator --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_scsi_dma --Mdir build/obj_tb_scsi_dma -o tb tb/tb_scsi_dma.sv tb/tb_scsi.sv rtl/hp98265a.sv rtl/hp98620.sv rtl/scsi/mb87030.sv rtl/scsi/scsi_target.sv && build/obj_tb_scsi_dma/tb` |

## Serial

| Bench | Status | Run |
|---|---|---|
| `tb_uart8250.sv` | **passes**. Covers internal loopback (data, IIR, MSR lines), THRE interrupt, 8N1 over a wire with the bit period checked, 7E1, a stick-parity error and overrun. It found a real bug: an LSR read in the same clock as a received error lost the error. | `verilator --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_uart8250 --Mdir build/obj_tb_uart -o tb tb/tb_uart8250.sv rtl/uart8250.sv && build/obj_tb_uart/tb` (iverilog is too slow for this one) |
