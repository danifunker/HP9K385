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

## Next gaps, in boot order

1. **VRAM** at `$200000` (2 MB, stride 2048) and the Catseye STATUS bits, so the console init and the card ROM checksum step (F3) run.
2. **8042** (real `1820-4784` firmware on an MCS-48 core, or HLE). The ROM waits on it at code 0x22.
3. **HP-IB** at `$47xxxx` (code 0x24) and DMA (0x28). Both are probed and may stay absent or stubbed for now.
