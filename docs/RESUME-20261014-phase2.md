# Resume prompt: Phase 1 and the Phase 2 hardware done in simulation; real software next

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

**`rtl/hp385_top.sv` models:**

- **CPU:** AP68040.
  - RAM window from `ram_mask`.
  - Bus masters in priority order: table walker, 98620 DMA, CPU.
  - DMA writes snoop the data cache.
- **PTM:** MC6840.
- **98550A:** Catseye and Nereid, on a VRAM port.
- **HIL card:**
  - The 8042 runs its real firmware on `upi41.sv`.
  - MLC loop with an ITF keyboard and a 46060B mouse (`hil_dev.sv`).
  - MSM58321 RTC and SN76494 beeper.
- **Built-in HP-IB:** reduced TMS9914.
- **98620C DMA.**
- **98265A SCSI** at select code 14: MB87030 SPC, disks on IDs 0 and 1, CD-ROM on ID 2 (`rtl/scsi/`, `docs/reference/scsi.md`).
- **98644 serial** at select code 9: INS8250.
- The RESET instruction does not reset DIO cards.

**MiSTer shell (`HP9K385.sv`):**

- PLL, SDRAM (RAM and ROMs), DDR3 VRAM with framebuffer and palette mirror.
- `boot0/1/2.rom` loaders.
- OSD slots S0/S1 (disks) and S2 (CD).
- PS/2 keyboard and mouse to HIL, RTC from hps_io, beeper audio, UART on the USER port.
- **First fit** (before SCSI and serial): 93 % ALMs; clk_sys −0.312 ns, all inside the AP040 fetch path.
- **Second compile:** see `build/quartus_compile2.log` / `output_files/` for the current size.

**Main_MiSTer:** branch `hp9k-family` has an `HP9K385` row (CD on slot 2, no LAN) as local commit 26113df. **Not pushed.**

**Sim results:**

- Every self-test passes.
- A self-made LIF system boots from SCSI ID 0 through a multi-block DMA read (`docs/BOOT_SIM.md`, `docs/reference/lif_boot.md`).
- `scripts/run_benches.sh` runs all unit benches; all pass.

## Next

1. **Real software.**
   - Get disk images for NetBSD/hp300, BASIC/WS 6.4, Pascal 3.25 or HP-UX 9.10. **Ask the user before downloading.**
   - Boot them in the sim (`--disk0`, `--cd`). The boot ROM needs about 110M clocks just to scan SCSI IDs 6..0. Consider putting the boot disk on a higher ID, or shortening the SPC selection timeout in sim only.
2. **If the ROM's SCSI error recovery comes up:** "Set ATN" while connected doesn't raise ATN in our MB87030. MAME behaves the same; check against the datasheet.
3. **Performance:**
   - Catseye window moves through the VRAM port are slow (a full-screen clear is ~2M clocks).
   - The SCSI disk has no read-ahead.
   - The CD makes four HPS round trips per 2048-byte block.
4. **Missing:** config EEPROM at `$400000`, Catseye RUG lines and bit mode (X11), LAN (98643 and Main's hp9k_enet), overlay compositing.
5. **Area and timing:** Catseye patterns and 8042 RAM are held in registers. Seed walk for clk_sys.
