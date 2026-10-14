# Resume prompt: Phase 1 done in simulation, Phase 2 (storage) next

Paste everything below the line into a fresh Claude Code session started in the repo root (`HP9K385/`).

---

We're building **HP9K385**, a MiSTer core for the HP 9000 Model 385: a 33 MHz 68040 using the AP68040 core, a 98550A Catseye graphics card, and the processor board's built-in I/O.

- Work is on `master` until the core is stable.
- Commit often, with clear messages.
- **Do not use the MiSTer hardware until the user says so.** Local Quartus builds are fine: `~/intelFPGA_lite/17.0`.

## Read first

1. `docs/PLAN_385.md`: phases and decisions log, including everything decided on 2026-10-14.
2. `docs/BOOT_SIM.md`: how to run the sim and compare with MAME, and what the boot ROM does today.
3. `docs/disasm/README.md`: what the boot ROM, 98550A ROM and 8042 firmware do, with addresses.
   - The annotated `.asm` listings are git-ignored. Regenerate them with `docs/disasm/tools/`.
4. `tb/README.md`: the unit benches and how to run them.

## State (end of 2026-10-14)

**Modelled in `rtl/hp385_top.sv`:**

- CPU: AP68040 through `wombat_cpu`.
  - RAM window from `ram_mask`.
  - Masters in priority order: MMU table walker, then the 98620 DMA, then the CPU.
  - DMA writes snoop the data cache.
- MC6840 PTM (`ptm6840.sv`).
- 98550A: Catseye with host RMW through the PRR rules (`catseye.sv`) and the window mover (4 pixels per clock, clipping, plane select, pattern), plus Nereid (`nereid.sv`). VRAM sits on its own port.
- HIL card:
  - The 8042 runs the real firmware on our UPI-41 core (`upi41.sv`).
  - MLC loop with an ITF keyboard and a 46060B mouse (`hil_dev.sv`).
  - MSM58321 RTC (`msm58321.sv`).
- Built-in HP-IB: card registers plus a reduced TMS9914 (`hpib.sv`).
- 98620C DMA (`hp98620.sv`). No card requests DMA yet.
- The RESET instruction does **not** reset the DIO cards (see the decisions log).

**MiSTer shell (`HP9K385.sv`):**

- 33/99 MHz PLL.
- SDRAM: RAM plus the boot and card ROMs (`rtl/mem/`).
- DDR3: VRAM, scanned out by the MiSTer framebuffer, with the palette mirrored from the Nereid (`vram_ddr3.sv`).
- `boot0/1/2.rom` loaders.
- PS/2 keyboard and mouse to HIL.
- Analysis & Synthesis passes. A full fit was started (`build/quartus_compile.log`); check its result: ALMs, timing.

**Sim results** (`make -C verilator run-fast`):

- Every self-test passes; final LED FF.
- The console shows Bit Mapped Video, MC68040, HP-HIL.Keyboard, HP-IB, DMA-C0 and RAM.
- A simulated RETURN reaches attended mode.

## Next

1. **SCSI (Phase 2).** A background agent was writing `rtl/scsi/mb87030.sv` (MB87030 SPC), `rtl/scsi/scsi_disk.sv` (SCSI disk target on a MiSTer block interface), `tb/tb_scsi.sv` and `docs/reference/scsi.md`. Check whether they exist and pass. Then:
   - Add the 98265A card at select code 14 (`$6E0000`), interrupt level 4 (card registers per MAME `hp98265a.cpp`), with SPC DREQ to dmar0/1 according to the control register's DE bits.
   - Connect the DMA's dack to the SPC.
   - Serve the disk's block interface from an image file in the sim, and add `sd_*` / `img_*` from hps_io (`S0`, `S1`) in the shell.
2. **A bootable test disk.** No HP 300 images are local. Ask the user before downloading one (for example NetBSD/hp300 install media). Alternatively, build a LIF volume with a small test program; the format is in NetBSD's `sys/arch/hp300/stand/mkboot`.
3. **Remaining devices:** SN76494 beeper to audio, 98644 serial, the config EEPROM at `$400000` (probed; absent is fine), Catseye line drawing and bit mode (needed for X11).
4. **Area and timing:** the Catseye pattern RAM and the 8042 RAM are held in registers (~7.5k registers together); move them to block RAM if the fit is tight.
