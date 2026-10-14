# Plan: HP 9000 Model 385 core for MiSTer

Target: **33 MHz MC68040 (AP68040 core from MacQuadra800_MiSTer) + HP 98550A "Catseye" 1280×1024×8 + the built-in I/O of the 380/385 processor board**, booting Boot ROM rev 2.0 → BASIC/WS 6.4, Pascal 3.25, NetBSD, HP-UX 9.10.

Reference material:
- `docs/SITE_NOTES.md`: facts from the hp-series300.net scrape. The raw mirror and text extracts are in `scratch/site/` and `scratch/text/`; they are not committed and travel in `scratch.zip`.
- `docs/reference/mame-hp380.md`: register-level spec distilled from MAME (`../mame/src/mame/hp/hp9k_3xx.cpp`, `src/devices/bus/hp_dio/*`, `src/devices/video/{catseye,nereid}.cpp`).
- `docs/reference/ap68040-integration.md`: the CPU and memory path from `../MacQuadra800_MiSTer`. Use that tree, not `-devel`, which is an older snapshot.
- `docs/reference/legacy-hp300-core.md`: what the 2020 `hp300_MiSTer` core did, and its bugs.
- `docs/ROMS.md`: ROM images, checksums and byte order.

## Decisions log

| Date | Decision |
|---|---|
| 2026-10-14 | **Fresh repo `HP9K385`** (github `danifunker/HP9K385`), started from `Template_MiSTer` @ `9c8eadb` (2026-10-10). Not a fork of `hp300_MiSTer`, because almost everything is replaced. Not a fork of the Quadra, to avoid inheriting Mac decode. |
| 2026-10-14 | CPU vendored, files only: `rtl/ap68040/` (byte-identical to Quadra @ `011f7d9`) plus `rtl/wombat/{wombat_cpu,wombat_store_buffer,wombat_bus32}.sv` and `rtl/wombat/dpram.v`. Not yet in `files.qip`. |
| 2026-10-14 | ROMs obtained and verified (MAME sets `hp9k380`, `dio98550`, `human_interface`). Boot ROM is **Rev 2.0, 29 Nov 90**. ROMs are never committed; see `docs/ROMS.md`. |
| 2026-10-14 | `scratch/` is git-ignored and moves between machines as `scratch.zip` (also ignored). Anything that must survive goes in `docs/`. |
| 2026-10-14 | `wombat_cpu` gets a runtime `ram_mask[11:0]` input (RAM = the top 2^n MB). The cacheable set is RAM plus the boot ROM; posted stores go to RAM only. `wombat_store_buffer` takes the window as `post_window`. Power-of-two RAM sizes only. |
| 2026-10-14 | `rtl/hp385_top.sv` is the MiSTer-independent system. ROM, RAM and the card ROM sit behind one generic memory port (sel 0/1/2); the sim serves it from host arrays. |
| 2026-10-14 | 8-bit devices on odd bytes go through one `io8` sequencer in the top. A beat is split into its odd lanes, one register access per clock, which matches the 030's dynamic bus sizing for longword/MOVEP accesses. Even lanes read 0xFF. |
| 2026-10-14 | Writes into boot-ROM space are acked and ignored, except the LED latch at `$1FFFC-F` (odd lanes). The ROM's reset stack is at `$100-$200` *in ROM space*, so bus-error frames land there before RAM is known. |
| 2026-10-14 | MC6840 written from the datasheet (`rtl/ptm6840.sv`): E/C1/C3 = 250 kHz (clk/132 at 33 MHz), O3→C2, IRQ 6. The comparison modes count as continuous because the gates are tied low. |
| 2026-10-14 | MAME is a reference, not an oracle. Its 68040 pushes format $B bus-error frames where a real 040 (and AP68040) pushes format $7. `compare_mame.py` treats the resulting `$13EC` handler detour as expected. |
| 2026-10-14 | ROM disassemblies (`docs/disasm/*.asm`) stay local (git-ignored) because they are derived from copyrighted ROMs. The analysis README and the generator and patch tools are committed. |

---

## 0. Where we're starting from

The existing core (Sven Schnelle, 2020) is a proof of concept. Almost everything except the MiSTer shell gets replaced:

| Block | Today | Fate |
|---|---|---|
| CPU | wf68K30L (68030, **no MMU/FPU/cache**), 50 MHz, async AS/DSACK | **Replace** with AP68040 |
| Boot ROM | Rev D (68030-era) baked into `bootrom_d.vhd` | **Replace** with rev 2.0 `1818-5062` (380/385), loaded at runtime |
| RAM | 2 MB @ 0xFFE00000, 16-bit SDRAM @ 50 MHz, ~9 clk/access | **Replace** with `sdram_beat32` (99 MHz, BL8 line fills); 8–128 MB |
| Video | Topcat 98544, 1024×768 **1 bpp**, BRAM VRAM; CPU readback is broken | **Replace** with Catseye 98550A |
| HIL | `hif.vhd`: tiny fake 8042, PS/2 → HP keycodes, no release codes, no mouse | **Replace** (8042 + MLC + HIL devices) |
| PTM 6840 | IRQ hard-wired off; counters only load the low byte | **Rewrite** |
| IPL encoder | Level 1 masks level 6 (priority bug) | **Rewrite** |
| HP-IB, SCSI, DMA, serial, LAN, RTC, beeper | absent / dummy ack | **New** |
| hps_io | `ioctl_download` wired to `status[1]` (bug); no file menu | **Rework** |
| Clocks | 64 MHz + 200 MHz with fabric dividers; no `.sdc` | **Replace** with Quadra-style 33/99 MHz PLL |

Keep: the `sys/` framework (update to the current Template_MiSTer), the CONF_STR skeleton and the LED-latch idea.

---

## 1. Target system definition (the "385" we build)

Memory map (32-bit; everything not listed → **bus error**, which the boot ROM relies on to probe):

| Address | Device | IRQ |
|---|---|---|
| 0x0000_0000–0x0001_FFFF | Boot ROM rev 2.0, 128 KB (27C210, 16-bit). Write to 0x1FFFC sets the 8 diag LEDs | |
| 0x0020_0000–0x003F_FFFF | 98550A VRAM, 2 MB, 1 byte/pixel, stride 2048 (internal-framebuffer location) | |
| 0x0042_0000 (+mirror) | 8042 HIL controller: data 0x420001, cmd/status 0x420003 | 1 (NMI 7 on kbd reset) |
| 0x0047_0000 (+mirror) | Built-in HP-IB (TMS9914) + status (KBDNMIST at 0x478005) | 3 |
| 0x0050_0000–0x0050_020F | 98620C DMA (2 channels, 32-bit extension at +0x100/+0x200) | 3–6 |
| 0x0056_0000–0x0056_FFFF | 98550A: ROM (odd bytes) + int reg; Catseye regs 0x564000; Nereid CLUT 0x566000 | 3–6 (vblank / wmove) |
| 0x005F_4000–0x005F_400F | System-control/"MMU" registers. MAME uses plain RAM, and the boot ROM crashes without it. **Research:** real 380 bits (see §6) | |
| 0x005F_8000–0x005F_800F | MC6840 PTM, odd bytes, 250 kHz clock on C1/C3, O3 cascades into C2 | 6 |
| 0x0060_0000 + sc×0x10000 | DIO-I select codes: **SCSI sc 14 (0x6E0000)**, serial sc 9 (0x690000), LAN sc 21 (0x750000) | per card |
| 0x0100_0000+ | DIO-II space: empty, bus error | |
| 0x1_0000_0000 − N MB … 0xFFFF_FFFF | Main RAM, grows downward (8 MB at 0xFF80_0000 standard) | |

Interrupts are all **autovectored**. That fits AP68040, which ignores IACK and always autovectors.

---

## 2. Components we need

Legend: **R** = reuse as-is or adapted, **P** = port from MAME C++ to RTL, **N** = new.

| # | Component | Source | Needed for | Effort |
|---|---|---|---|---|
| 1 | **AP68040 CPU** (int + MMU + FPU subset + 8K/8K write-through caches) | R: `MacQuadra800_MiSTer/rtl/ap68040/rtl/*`, `wombat_cpu.sv`, `wombat_store_buffer.sv`, `wombat_bus32.sv` | everything | M |
| 2 | **DIO bus bridge** (beat bus → 8/16/32-bit DIO cycles, byte-lane steering, BERR/timeout) | N | all I/O | M |
| 3 | **Memory system**: SDRAM line fills, fast path, walker port, DMA snoop | R: `sdram_beat32.sv` + `sdram.sv`; patterns from `quadra800.sv:577-690` | perf | M |
| 4 | **Boot ROM rev 2.0** `1818-5062_98754_9000-380_27c210.bin` (CRC 500a0797) | user-supplied, loaded via ioctl into SDRAM or DDR3 | boot | S |
| 5 | **System-control regs @ 0x5F4000** + LED latch | N (stub first) | boot | S |
| 6 | **MC6840 PTM** (full: 16-bit latches, modes, status, IRQ) | P/N (rewrite `ptm6840.vhd`) | OS clock tick | S |
| 7 | **Interrupt controller / IPL priority encoder** | N | all | S |
| 8 | **98550A Catseye**: register file ×8 planes (one shared impl), PRR/WRR rules, window mover, RUG line draw, bit mode, clipping, patterns; overlay bank | P: `catseye.cpp`/`hp98550.cpp` | console + X | **L** |
| 9 | **Nereid colormap** (512×24-bit, overlay ctl, plane mask) | P: `nereid.cpp` | colour | S |
| 10 | **98550A card ROM** `98550a.bin` (32 KB, CRC 9d639233): DIO ID + fonts | user-supplied; BRAM 32 KB or SDRAM | console | S |
| 11 | **VRAM + scanout** (2 MB video + overlay planes) | N, see §4 | display | **L** |
| 12 | **8042 HIL controller**: real firmware `1820-4784.bin` (CRC e929044a) on an MCS-48 soft core (T48/OpenCores), or an HLE of the 8042 host protocol | R/N | keyboard, RTC, beep | M |
| 13 | **HP-HIL MLC** + keyboard (46021A ITF) + mouse (46060B) devices; PS/2→HIL keycode tables; MiSTer mouse → HIL relative motion | P: `bus/hp_hil/*` | input | M |
| 14 | **MSM58321 RTC** (behind the 8042), seeded from hps_io `RTC` | N | clock | S |
| 15 | **SN76494 beeper** → MiSTer audio (any SN76489 core) | R | beep | S |
| 16 | **98620C DMA** (byte/word/long, dmar/dmack) | P: `hp98620.cpp` | SCSI/HP-IB DMA (NetBSD requires it) | M |
| 17 | **98265A SCSI**: DIO wrapper + **MB87030 SPC** + SCSI target(s) backed by MiSTer block devices (HDD ×2 + CD-ROM 512 B/sector) | P: `hp98265a.cpp`, `mb87030.cpp`; target side from an existing MiSTer core (MacPlus/Quadra `scsi*`) | disks — **the primary storage path** | **L** |
| 18 | **98644 serial** (INS8250 @ 2.4576 MHz) → MiSTer UART/USER port | R: Quadra `rtl/uart` or any 16450 core | serial console, debug | S |
| 19 | **Built-in HP-IB** (TMS9914 + status regs @ 0x470000) + optional **CS/80 disk emulation** (HPDrive-style `.hpi`) | stub now, P later | BASIC/Pascal `.hpi` images | S stub / L full |
| 20 | **98643 LAN** (Am7990 LANCE + 16 KB card RAM + MAC NOVRAM) → MiSTer HPS Ethernet bridge | N; host transport from the Quadra SONIC work (`danifunker/Main_MiSTer` `mac-ethernet-pr`) | networking | L (phase 5) |
| 21 | **Config EEPROM** X2816 (2 KB): the rev 2.0 ROM stores boot defaults there | N, saved via MiSTer save file | nicety | S |
| 22 | **Parallel port** | stub / skip | — | — |
| 23 | **MiSTer shell**: PLL 33/99 MHz (+108 MHz video if native), CONF_STR (ROM/image loaders, RAM size, CPU speed 25/33 MHz, aspect), `.sdc`, current `sys/` | N | — | M |
| 24 | **Main_MiSTer support**: none required for the base; Ethernet needs a Main patch | — | LAN | — |

ROM images (#4, #10, #12) are copyrighted, so ship them **as user-provided files** (`games/HP300/boot.rom`, etc.), not in the repo. The current `bootrom_d.vhd` embedding should go away.

---

## 3. CPU integration (component 1–3) — details

- Lift `rtl/ap68040/rtl/*.v`, `ap040_defs.svh`, `ap040.qip`, `wombat_cpu.sv`, `wombat_store_buffer.sv` and `wombat_bus32.sv`. Use the MiSTer altsyncram `dpram`.
- Parameterize the Mac-specific predicates in `wombat_cpu.sv`:
  - `cache_allow` (`:411`) → **RAM window (top N MB) + boot ROM**. DIO space, 0x5Fxxxx and VRAM must be non-cacheable. VRAM goes non-cacheable because the window mover changes it behind the CPU's back.
  - `c_post_ok` (`:448-451`) → RAM only; VRAM only if the VRAM path can absorb posted writes.
- Clocks: `clk_sys` = 33.000 MHz, `clk_ram` = 99 MHz. This is exactly the Quadra PLL, so lift it. 33 MHz is the 385 spec.
  - Provide a "380 (25 MHz)" menu option by throttling `ce` (3 of 4 cycles), not with a second PLL.
- **Start with the `AP040_EXPERIMENTAL_*`/`AP040_PIPELINE_*` macros OFF.** That gives a smaller, easier-to-time core. Turn them on later if area allows. The Quadra build sits at 93% ALM and timing is a seed lottery, so we need the headroom.
- **FPU:** transcendentals and packed decimal trap to the FPSP, as on a real 040. HP-UX 9 and NetBSD ship an FPSP. **Risk:** BASIC/WS 6.x and Pascal 3.25 must also carry an 040 FPSP. They should, because the real 380 needs one too; verify early.
- **Write-through caches only** (no copyback). The OSes may enable copyback in the MMU descriptors; the core treats it as write-through, which is safe.
- Bus bridge (#2) is a small FSM: beat → DIO cycle with `be[3:0]` → UDS/LDS/byte lanes. Rules:
  - **8-bit odd-byte devices** (8042, PTM, SPC, 8250, Nereid, card ID regs) get data on D23:16 (odd byte of a 16-bit word). A longword access to them must be split, as the 030's dynamic bus sizing would have done.
  - 16-bit devices (Catseye regs).
  - 32-bit (VRAM, RAM, ROM).
  - Unmapped → `berr` pulse → format $7 frame. Keep `ap040_bus_timeout`.
- Interrupts: `ipl[2:0]` from the new priority encoder.
- The DMA engine writes RAM → pulse `snoop_stb`/`snoop_addr` so the D-cache drops stale lines.
- RAM-size option: 8 / 16 / 32 / 64 MB (128 MB needs the dual-SDRAM board). The boot ROM sizes RAM by probing down from 0xFFFFFFFF until a bus error, so the decoder must bus-error below the configured base.

## 4. Video design (components 8–11) — the big decision

98550A VRAM is 2048×1024 bytes = **2 MB**, plus 2 overlay planes. The Cyclone V has ~690 KB of M10K total, so **VRAM cannot live in BRAM** (the current core's approach). Options:

| | A. MiSTer framebuffer in DDR3 (recommended first) | B. Native scanout from SDRAM/DDR3 |
|---|---|---|
| How | VRAM lives in DDR3; set `FB_EN`, `FB_FORMAT`=8bpp indexed, `FB_STRIDE`=2048, `FB_WIDTH/HEIGHT`=1280×1024. Nereid CLUT writes → `FB_PAL_*` | Own 108.108 MHz timing (htotal 1689, vtotal 1066), line-buffer prefetch, own CLUT in BRAM |
| Pros | ascal does all scanout, so no 78 MB/s read load on our memory; HDMI any mode | Analog VGA/direct video works; overlay planes compositable in hardware |
| Cons | HDMI only (no analog out); overlay planes not composited; DDR3 latency on CPU VRAM reads | 108 MHz clock domain, bandwidth contention, more BRAM |

Plan: do **A** first, then add B as an option later if analog out matters.
- Store overlay planes in a separate DDR3 region; ignore them for display until B. Only Starbase uses them; BASIC, NetBSD and X11 basic mode don't.
- The window mover and RUG engine work on DDR3 through a small read/write line cache. Console scroll is just window moves.
- Implement Catseye as **one** engine operating on 8-bit pixels with a per-plane enable mask, not 8 instances. All 8 instances get identical writes and reads are ORed, which collapses to byte-wide ops plus plane masks.
- Status/VBLANK regs and vblank IRQ must work; MAME has bugs here, so don't copy them.

## 5. Phased roadmap

Each phase ends with a concrete, testable milestone.

**Phase 0: scaffolding (sim first)**
1. Repo layout:
   - Already done: `sys/` (current template), `rtl/ap68040/`, `rtl/wombat/`.
   - To add: `rtl/dio/`, `rtl/video/`, `rtl/hil/`, `rtl/scsi/`, a 33/99 MHz PLL replacing the template demo `rtl/pll*`, and a new `.sdc`.
   - Delete the template demo (`mycore.v`, `lfsr.v`, `cos.sv`) once `HP9K385.sv` instantiates the real system.
2. Port the AP68040 standalone tests (`rtl/ap68040/tb/run_tests.sh`, iverilog + vasm) into this repo so CPU regressions are caught here.
3. Verilator full-system sim modelled on `MacQuadra800_MiSTer/verilator/`: CPU + ROM + RAM + bus-error decode + LED latch + trace of PC/LED writes. Drop the old ModelSim flow.
- **Milestone:** rev 2.0 boot ROM runs its self-test in sim and the LED codes advance. Compare against MAME `hp9k380` with `-debug` for an instruction-level trace diff.

**Phase 1: boot to the ROM menu on screen**
4. PTM rewrite + IPL encoder + 0x5F4000 regs.
5. Catseye minimal: ROM at 0x560000, VRAM in DDR3 (option A), PRR host writes, window mover, VBLANK, Nereid CLUT.
6. 8042 + MLC + ITF keyboard (input).
7. hps_io: boot ROM / 98550A ROM / 8042 ROM loaders and a RAM-size option.
- **Milestone:** on hardware, "Bootrom Rev 2.0 … 68040 … RAM nnnn MB … Searching for a system" on the 1280×1024 console, with the keyboard working.

**Phase 2: storage**
8. 98620C DMA.
9. 98265A + MB87030 SPC + SCSI HDD/CD targets on MiSTer image slots (`S0`, `S1`, CD `S2`).
10. Built-in HP-IB TMS9914 kept as a responsive stub (ID 0x80, no devices).
- **Milestone:** the boot ROM lists a LIF system on a SCSI image. BASIC/WS 6.4 and Pascal 3.25 boot from the hp-series300.net ISO/disk images.

**Phase 3: Unix**
11. RTC, beeper, HIL mouse, 98644 serial (MiSTer UART).
12. Config EEPROM persisted as a save file.
- **Milestone:** NetBSD 9.x/10.x hp300 boots multi-user from SCSI (exercises MMU, FPSP, DMA and PTM). HP-UX 9.10 installs from the CD image.

**Phase 4: performance and polish**
13. Turn on the AP040 pipeline macros if area allows; RAM fast paths; timing closure at 33 MHz.
14. Full Catseye (RUG lines, patterns, clipping, bit mode) for X11 and HP VUE.
15. Optional native 108 MHz scanout (option B) for analog VGA and overlay planes.

**Phase 5: networking and extras**
16. 98643 LANCE ↔ MiSTer Ethernet (Main_MiSTer patch reused from the Quadra Ethernet work).
17. Optional HP-IB CS/80 disk emulation for `.hpi` images, and a 98624 card.

## 6. Open questions / research items

1. **0x5F4000 register semantics on the 380.** NetBSD `sys/arch/hp300/hp300/locore.s` / `machdep.c` identify the model by the "MMU ID" byte there and by CPU type. What value makes it report a **380/385**? (Rather than a 425, which is also an 040.) Also check its cache/parity control bits. Fetch the NetBSD source and read it before Phase 1.
2. ~~**ROM dumps**~~: **resolved 2026-10-14**. All three were obtained and their SHA1s verified (`docs/ROMS.md`). Still open: the config EEPROM image, which the site says is on Bitsavers.
3. **Does anything distinguish 385 from 380 besides clock?** The site says the processor board is identical, with a 25/33 jumper that adds a RAM wait state. Check whether the jumper is software-readable (possibly at 0x5F4000), or whether the OS just measures CPU speed.
4. **FPSP in BASIC/WS and PAWS:** confirm they handle the unimplemented-FP traps (F-line, vector 11) on the 040. The AP040 FPU matches a real 040's implemented subset, so they should.
5. **FPGA area:** CPU ~25k ALMs (less with pipeline macros off) + Catseye engine + SCSI/SPC + 8042 + DMA. Catseye and SPC are the big unknowns. Do a first full fit at the end of Phase 1 to get a real budget before adding LAN.
6. **Native 1280×1024 analog out:** 108 MHz pixel clock is fine on Cyclone V, but DDR3/SDRAM bandwidth for scanout plus CPU needs measuring (deferred to Phase 4).
7. **MAME bugs not to copy:** Catseye IRQ plane-0 callback, `vblank_w` missing `update_int`, 98644 IRQ not wired, `buserror_r` rw flag.

## 7. Immediate next steps

1. Fetch NetBSD hp300 sources (locore.s, machdep.c, `dev/{spc,dma,hil,diofb,nereid}*`) into `scratch/` to settle §6.1/§6.3 and to serve as a second spec next to MAME. Record the conclusions in `docs/`.
2. ~~Locate the three ROM images and verify their CRCs~~ (done).
3. ~~Phase 0 steps 1–3~~ (done 2026-10-14; results in `docs/BOOT_SIM.md`). The ROM reaches the 8042 self-test (code 0x22) in sim. Next: VRAM + Catseye STATUS, then the 8042 (Phase 1 items 5-6).
