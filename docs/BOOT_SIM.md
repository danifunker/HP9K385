# Boot ROM Rev 2.0 in simulation (Phase 0)

What the Rev 2.0 boot ROM does in the Verilator full-system sim, and how that compares with MAME's `hp9k380`.

- The routine-level analysis (addresses, LED-code meanings, patch points) is in `docs/disasm/README.md`.
- This file records **observed behaviour**.

## Running it

```
scripts/cpu_regression.sh                  # AP68040 self-tests, 3 legs (~20 min)
make -C verilator                          # build obj_dir/Vhp385_top (~4 min)
make -C verilator run CYCLES=60000000      # boot; logs in verilator/out/
scripts/eventsum.py verilator/out/events.log
scripts/mame_trace.sh build/mame 4         # MAME reference (needs scratch/roms/zips)
scripts/compare_mame.py                    # LED / device / instruction-stream diff
```

- **Sim speed:** about 350k clocks/s, i.e. 1 s of 33 MHz time takes about 95 s of wall time.
- **Fast boot:** `docs/disasm/tools/bootrom_simpatch.py` builds a sim-only ROM that skips the lamp-test delay, the RAM test, the LED blink and the checksum loop. It recomputes the checksum long, so the ROM's own check still passes.

## System modelled (2026-10-14)

| Block | State |
|---|---|
| CPU | AP68040 through `wombat_cpu`, caches on, no `AP040_*` macros |
| Boot ROM, 8 MB RAM, 98550A card ROM | host arrays behind the memory port, 2-clock latency |
| `$5F4000` | 16 bytes of RAM |
| MC6840 PTM | `rtl/ptm6840.sv`, IRQ 6 |
| 8042, HP-IB, Catseye/Nereid registers | ack-only stubs. Catseye STATUS reads 0x0A; MAME's reads 0x0E (bit 2, unclipped, is set) |
| VRAM `$200000-$3FFFFF` | **not mapped (bus error)** |
| Everything else | bus error |

## Observed sequence

The raw LED latch value is `~code`. The codes are in `docs/disasm/README.md` §1.4.

| Clock | Raw LED | Code | What the sim shows |
|---|---|---|---|
| 0 | | | Register test passes three times. The first bus error at `$41C0C0` (FRODO, 4xx only) pushes a format $7 frame into ROM space at `$1C4-$1FF`; the writes are ignored. |
| 60k | 80…FE | — | Probe `$FF7FFFFC` (just below 8 MB) bus-errors, then the lamp test. |
| 2.05M | FD | 0x02 | Top-16K RAM test. Probes `$51FFFC`, `$41C0C0`, `$400000`, `$880000` (all bus error). Writes `$5F400E` = 0. |
| 3.92M | DF | 0x20 | PTM init: CR3 = $84, T2/T3 latches = FFFF. T2:T3 is polled as a 32-bit counter. **Without a counting PTM the ROM halts here with `STOP #$2700` at `$13E4`.** |
| 3.93M | FA | 0x05 | ROM-extension scan, `$20000-$3FC000` in 16K steps. Ours bus-errors throughout; in MAME, VRAM answers from `$200000`. |
| 4.14M | F8 / F7 | 0x07 / 0x08 | Self-test executor. Step 31000 sends 8042 command 0x31 at **`$428003`** (status read at `$428003` first) and re-inits the PTM. |
| 4.147M | | | Step 30990: `ori.w #$60,$5F400E`, then `move.b #7,$5F4003`. Probe `$30000040` (bus error). |
| 4.149M | F6 / D2 | 0x09 / 0x2D | Console search finds the 98550A: ID 0x39 at `$560001`. Bitmap console init from the card-ROM tables: Nereid regs `$566040-$5660BC`, Catseye banks `$5645xx/$5647xx`, window-move clear (`$564308`), STATUS poll, colormap entries 0, 1, FF. |
| 4.173M | | | **First VRAM write at `$200000` bus-errors**: the first gap. |
| 4.175M | | | DIO-II scan `$1000000-$1FC00000` in 4 MB steps (bus error), then DIO-I select codes 0-31 at `$600000-$7F0000` (bus error). Probes `$510000`, `$538000`, `$5D0000`. |
| 4.29M-6.8M | D1 / F1 / D2 / D1 | 0x2E / 0x0E / … | Alpha probe, boot ROM checksum, console line. |
| 6.79M | DD | 0x22 | **8042/HIL self-test: polls `$428003` forever.** The 8042 is the first device we don't model. |

## MAME comparison (`scripts/compare_mame.py`)

MAME 0.285 `hp9k380` is configured with the 98550A in sl1, the other slots empty and no HP-IB disk. Its LED sequence is:

> 80 C0 E0 F0 F8 FC FE FD DF FA F8 F7 F6 D2 **F3** D1 F1 D2 D1 DD F0 D0 DB D7 EF …

- **Up to DD, ours is identical** except for F3 (code 0x0C, card ROM checksum). The ROM skips that step in our run, presumably because the console init above went another way without VRAM.
- **After DD,** MAME continues with RAM sizing (F0), the video RAM test (D0), HP-IB (DB), DMA (D7) and the RAM test (EF), because its 8042 runs real firmware.

**Instruction stream.** The streams match for the first **1.61 million** MAME dispatches, with two kinds of expected difference:

- **Bus-error frame format.** For a 68040 bus error, MAME pushes a 68030 format $B frame (`m68kcpu.h:1668`, *MAME-GAP*). AP68040 pushes the correct format $7. `buserr_frame_cleanup` (`$13EC`) branches on the format at `$13FC`, so every bus error takes a different nine-instruction path through it and then rejoins. The comparator reports this once and counts it (123 times).
- **First real divergence** is at `$8D6`, the ROM-extension scan reaching `$200000`. MAME has VRAM there; we bus-error.

**Device-access order** matches up to the same VRAM point. After that, MAME reads `$5671xx`/`$5672xx` (Catseye/Nereid area), while ours goes straight to DIO-II.

**Instruction-trace artifact.** AP68040 dispatches a taken branch with `pc_i` already set to the target. The sim trace therefore shows the target PC twice and never the branch's own PC. `compare_mame.py` drops the duplicate.

## Answers to the Phase 0 questions

- **LED codes and where it stalls:** see the table above. The stall is at code 0x22 (raw DD), the 8042 self-test.
- **`$5F4000`:** written three times and never read for a decision: `$5F400E` = 0, `$5F400E` |= 0x60, `$5F4003` = 7. 16 bytes of RAM is enough for the boot ROM. What the OS needs there is still open (PLAN §6.1).
- **RAM sizing:** the reset path probes `$FF7FFFFC`. Step 1000 (`$1BD2`) later sizes downward from the top with `move.l A0,(A0)` until a bus error. RAM must bus-error below the configured base, which `hp385_top` does.
- **Console search:** yes. The ROM finds the 98550A at `$560000` through its card ROM (odd bytes) and initializes it from the card-ROM tables. Without VRAM, the first pixel write bus-errors.
- **Device probe list:**
  - FRODO `$41C0C0`
  - `$400000` (config EEPROM controller)
  - `$51FFFC`, `$510000`, `$538000`, `$5D0000`, `$880000`, `$30000040`
  - DIO-II `$1000000+n*$400000`
  - DIO-I select codes 0-31
  - 8042 at `$428001/3`; HP-IB at `$47xxxx` (after DD in MAME)
  - Every one of these must bus-error quickly when absent.
- **Checksum and RAM test:** `$5052` / `$18F6` and `$2528` (flag at `$46A`). The fast-boot patcher handles both. With 8 MB, the sim reaches DD in 6.8M clocks without patches, so we don't need them yet.

## Phase 1 progress (2026-10-14, later the same day)

Modelled since the Phase 0 run above:

- 98550A Catseye and Nereid, with VRAM through the `vram_*` port.
- The 8042 running the real firmware on `rtl/upi41.sv`.
- The HIL MLC with an ITF keyboard.
- The built-in HP-IB as a reduced TMS9914.

**Results:**

- **Fast-boot ROM** (`make -C verilator run-fast`): every self-test passes and the final LED is FF. The console shows "HP-HIL.Keyboard / HP-IB / RAM 8388292 Bytes" and "System Search Mode", the same as MAME.
- **Key input:** a RETURN injected with `--key 45000000:DA --key 46500000:DB` switches the ROM to attended mode ("Select System, type RETURN").
- **Unpatched ROM:** the LED sequence matches MAME through DD, including F3.

**Bugs found while bringing it up:**

- **The RESET instruction must not reset the DIO cards.** The boot ROM executes RESET about 0.1 s after power-up, while the 8042 is still configuring the HIL loop. A reset at that point warm-starts the 8042 with the loop configuration half done, so no keyboard is found.
- **The Catseye's full-screen clears are slow** with the sim's 2-clock VRAM port: about 2.3M clocks for a 1280×1024 clear. The CPU waits behind them. Use `--loop-window 10000000` (or 0) so the stall detector doesn't fire.

## Phase 2 progress: booting from SCSI (2026-10-14, evening)

**Added:**

- 98620C DMA.
- 98265A SCSI at select code 14:
  - MB87030 SPC.
  - Disks on IDs 0 and 1.
  - CD-ROM on ID 2.
- 98644 serial at select code 9.
- HIL mouse.
- MSM58321 RTC.
- SN76494 beeper.

The console now also lists "DMA-C0" and "HP98265 (SCSI S 32) at 14".

**Boot test:**

```
tools/bootblk/build.sh                         # build/hp385_testboot.img (LIF, SYSTEST)
cd verilator && ./obj_dir/Vhp385_top --rom out/bootrom_fast.bin \
    --card-rom ../scratch/roms/dio98550/98550a.bin --hil-rom ../scratch/roms/human_interface/1820-4784.bin \
    --disk0 ../build/hp385_testboot.img --cycles 200000000 --stop-pc FFF00072 --snap out/screen.ppm
```

- The ROM scans SCSI IDs 6..0. Each empty ID costs a 250 ms selection timeout, so ID 0 comes up around 108M clocks.
- It then reads the LIF volume, lists "1S SYSTEST" and auto-boots it.
- The test program loads through a multi-block DMA read, prints two lines through the ROM's console entry `$150`, draws VRAM bars and sets the LEDs.
- The boot protocol is documented in `docs/reference/lif_boot.md`.

**Bugs found on the way:**

- **98620 DMA count:** it must end at −1 (as in MAME). The ROM compares it with the SPC residue.
- **UART:** an LSR read in the same clock as a received error lost the error.
- **PTM:** a time-out in the same clock as a flag clear was lost.

**Open (low confidence):** in the ROM's SCSI error-recovery path, "Set ATN" while connected does not raise ATN. That matches MAME's MB87030, so it needs the datasheet. Normal boots don't use this path.

## Next gaps, in boot order

1. ~~VRAM, Catseye and Nereid~~, ~~8042 + HIL keyboard~~ and ~~HP-IB self-test~~: done.
2. ~~**Boot devices:** 98620 DMA and 98265A SCSI~~: done; a LIF test system boots from SCSI. Next: real software (NetBSD/hp300, BASIC/WS, HP-UX), which needs disk images; ask before downloading.
3. **MiSTer shell:** PLL, SDRAM for RAM and ROM, DDR3 for VRAM and scanout, loaders. Then a first Quartus fit.
4. ~~**Smaller items:** HIL mouse, MSM58321 RTC, SN76494 beeper, 98644 serial~~: done. Still to do: the config EEPROM at `$400000`, Catseye line drawing and bit mode (for X11), and LAN.
