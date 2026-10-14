# MAME reference: HP 9000/380 + 98550A

MAME tree: `../mame` @ `f34f02505e3` (2026-07-30). All paths below are under `src/`.

The `hp9k380` driver is **MACHINE_NOT_WORKING**. Treat MAME as a register-level spec, not as ground truth. Known MAME bugs are marked **MAME-GAP**; do not copy them.

## Driver: `mame/hp/hp9k_3xx.cpp`

- **CPU:** `hp9k380` = `hp9k360` config with an `M68040` at **25 MHz** (lines 432-438). We run at 33 MHz.
- **ROM:** `1818-5062_98754_9000-380_27c210.bin`, 128 KB, `ROM_LOAD16_WORD_SWAP` at 0 (lines 497-500).
- **RAM:** 0xFF800000-0xFFFFFFFF (8 MB) (line 208). RAM always grows down from 0xFFFFFFFF.
- **Default handler:** every address bus-errors (lines 281-319).
  - Reads return 0xFFFFFFFF and assert BERR, which clears after 16 CPU cycles (so RMW can complete).
  - **MAME-GAP:** `buserror_r` passes rw=false.
  - **The boot ROM relies on BERR to probe select codes, DIO-II and RAM size.**
- **Default slots** (DIO32, inherited from the 360, lines 415-420):
  - sl0 `human_interface` (fixed), sl1 `98550`, sl2 `98644`, sl3 `98620`, sl4 `98265a`.
  - There is no LAN by default.
- **IRQs:** 1 = HIL/8042, 3 = built-in HP-IB, 6 = PTM, 7 = keyboard-reset NMI. Cards jumper-select 3-6.

### Memory map

| Address | Device |
|---|---|
| 0x00000000-0x0001FFFF | Boot ROM. A write to 0x1FFFC sets the 8 diag LEDs (`led_w`, low byte lane) |
| 0x00200000-0x003FFFFF | 98550 VRAM |
| 0x00420000 (mirror to 0x42FFFF) | 8042: data 0x420001, cmd/status 0x420003 |
| 0x00470000 (mirror to 0x47FFFF) | Built-in HP-IB + status |
| 0x00500000-0x0050020F | 98620 DMA |
| 0x00560000-0x0056FFFF | 98550 ROM / control / colormap |
| 0x005F4000-0x005F400F | Plain RAM: "somehow coprocessor related - bootrom crashes if not present" |
| 0x005F8000-0x005F800F | MC6840 PTM, umask 0x00FF00FF (odd bytes). C1/C3 = 250 kHz, O3 → C2, IRQ6 |
| 0x00600000 + sc*0x10000 | DIO-I select codes 0-31 |

**MAME-GAP:** DIO-II select codes (sc ≥ 32 at 0x01000000 + (sc-32)*0x400000) are not implemented.

The header TODO (lines 47-57) lists: BBCADDR 0x420000, RTC_DATA 0x420001, RTC_CMD 0x420003, HIL 0x428000, HPIB 0x470000, KBDNMIST 0x478005, DMA 0x500000, FRAMEBUF 0x560000.

## DIO card conventions (`bus/hp_dio/hp_dio.*`)

- **base+1:** read = ID (bit 7 = remote jumper); write = card reset.
- **base+3:** interrupt control.
  - Bit 7 IE, bit 6 IRQ pending.
  - Bits 5:4 = level − 3.
  - Bits 1:0 = DMA channel enables.
- **Card IDs:** 98624 0x01, 98644 0x02, 98265A 0x07, 98643 0x15. Graphics cards take theirs from ROM.
- **Bus signals:** 7 IRQ lines wire-ORed, two DMA request lines (dmar0/1), dmack broadcast.

## HP 98550A Catseye (`bus/hp_dio/hp98550.cpp`, `video/catseye.*`, `video/nereid.*`)

- **ROM:** `98550a.bin`, 32 KB. `rom_r` returns `0xFF00 | rom[word]`, so ROM bytes appear at **odd addresses**.
  - 0x560001: ID read / reset write.
  - 0x560003: interrupt register (bit 7 IE, bits 5:3 level).
- **VRAM:** 2 MB at 0x200000, 1 byte/pixel, **stride 2048**, 1280x1024 visible.
  - Bit n of each byte = plane n = Catseye instance n.
  - The overlay is in a second 4 MB half of the 8-bit space (only 2 MB of it is used).
- **Timing:** 108.108 MHz pixel clock, htotal 1689, vtotal 1066, visible 1280x1024, ~60.04 Hz.
- **Instances:** 8 identical Catseye instances. All receive every write, and reads are ORed. Each register's plane-enable bit is bit 8+n.
  - Two register banks: TC1 (video) and TC2 (overlay).
  - **Implement as one byte-wide engine with plane masks.**

### Registers (0x564000 + 2*word)

**Topcat-compatible:**

| Address | Register |
|---|---|
| 0x564040 | VBLANK |
| 0x564044 | WMOVE_ACTIVE |
| 0x564048 | VBLANK_INTRQ |
| 0x56404C | WMOVE_INTRQ |
| 0x564080 | DISPLAY_PLANE_ENABLE |
| 0x564084 | SYNC_ENABLE |
| 0x564088 | WRITE_ENABLE |
| 0x56408C | READ_ENABLE |
| 0x564090 | FB_WRITE_ENABLE |
| 0x564094 | WMOVE_IE |
| 0x564098 | VBLANK_IE |
| 0x56409C | START_WMOVE |
| 0x5640A0 | BLINK |
| 0x5640A8 | ALT_FRAME |
| 0x5640EA | PRR |
| 0x5640EE | WRR |
| 0x5640F2 / F6 | SRC X / Y |
| 0x5640FA / FE | DST X / Y |
| 0x564102 / 106 | W / H |

**Catseye extensions:**

| Address | Register |
|---|---|
| 0x564200 | WMX |
| 0x564204 | RUG_REV / misc (bit 7 clip) |
| 0x564206 | RUG_SC (0x90 = blit, 0x10 + VB bit 8 = line) |
| 0x564208 / 0A | WMWIDTH / WMHEIGHT |
| 0x56420C | LINEPATH |
| 0x56420E | LINETYPE |
| 0x564210-216 | Src/dst XY |
| 0x564218-21E | Clip L/R/T/B |
| 0x564308 / 30A / 310-316 | "T" variants: a write triggers the operation |
| 0x564400-4FF | PATTERNS1 |
| 0x564500 | FBEN1 |
| 0x564502 | PRR1 |
| 0x564504 | TCREN1 |
| 0x564506 | WRR1 |
| 0x564508 | TCWEN1 |
| 0x56450A | BARC_REV1 (=0x0100) |
| 0x56450C | TRR1 |
| 0x56450E | COLOR1 |
| 0x564510 | VB1 |
| 0x564512 | TRRCTL1 |
| 0x564514 | ACNTL1 (0x100 bit mode, 0x200 overlay access) |
| 0x564516 | PLANEMODE1 |
| 0x564600 / 0x564700 | Bank 2 equivalents |
| 0x564800 | STATUS |

- **STATUS:** 0x02 ready, 0x08 no daughterboard, 0x04 unclipped, 0x10 vblank.
- **Replacement rules:** PRR applies to host writes (bits 11:8); WRR applies to the window mover (bits 3:0).
  - 16 rules: 0 clr, 1 s&d, 2 s&~d, 3 s, 4 ~s&d, 5 nop, 6 xor, 7 or, 8 ~s&~d, 9 ~s^d, 10 ~d, 11 s|~d, 12 ~s, 13 ~s|d, 14 ~s|~d, 15 set.
- **Window move:** overlap-safe (copy direction depends on src/dst order). The triple-rule pattern supports only TRR=0xF0.
- **MAME-GAPs:**
  - The IRQ callback passes the plane number, so plane 0 never interrupts.
  - `vblank_w` doesn't call `update_int`.
  - STATUS mask is not cleared on read.

### Nereid colormap

Low byte at `0x566000 + 2*reg + 1`:

| Address | Register |
|---|---|
| 0x566003 | BUSY (reads 0) |
| 0x5660A3 | OVERLAY_CTL |
| 0x5660B1 | INDEX0 |
| 0x5660B3 / B5 / B7 | R / G / B |
| 0x5660B9 | INDEX (stored **inverted**) |
| 0x5660BB | PLANE_MASK |
| 0x5660BD | OVERLAY_INDEX |
| 0x5660BF | REV (=1) |
| 0x5660F1 | WRITE_STROBE |
| 0x5660F9 | READ_STROBE |

- There are 512 entries: 0-255 video, 0x100+ overlay.
- **Pixel output:** `ovl &= OVERLAY_CTL`. If `ovl` is non-zero, output `pen[0x100|(ovl&mask)]`; otherwise `pen[video&mask]`.

### Catseye vs Topcat

- Topcat has only the 0x20-0x89 register set and adds a hardware cursor.
- Topcat has no RUG, lines, clipping, patterns, bit mode or overlay bank.

## human_interface (`bus/hp_dio/human_interface.*`)

- **Parts:**
  - i8042AH at 5 MHz running **real firmware** `1820-4784.bin` (2 KB), not HLE.
  - HP-HIL MLC (HLE, 8 MHz).
  - SN76494 beeper (333,333 Hz).
  - MSM58321 RTC (32.768 kHz).
  - TMS9914 HP-IB (5 MHz) with a 9122C on it.
- **8042 host interface:** 0x420001 data, 0x420003 cmd/status, mirrored across 0x42xxxx.
- **HP-IB block** at 0x47xxxx, odd bytes:

| Address | Register |
|---|---|
| 0x470001 | ID 0x80 / reset |
| 0x470003 | Bit 6 IRQ, bit 0 DMA, bit 7 reads 1 |
| 0x470005 | 0x81 always set; bit 6 = not controller-in-charge; **bit 2 = KBD NMI status** (= 0x478005 via mirror) |
| 0x470007 | Parallel poll control |
| 0x470009 | Parallel poll mask |
| 0x470011-01F | TMS9914 regs 0-7 |

  HP-IB uses IRQ3 and dmar0.
- **8042 ports:**
  - P1 = shared data bus (MLC, SN76494, RTC).
  - P2 bits:
    - 0 HIL_CS
    - 1 HIL_WE / RTC addr-write
    - 2 HIL_OE / RTC write
    - 3 latch enable
    - 4 → IRQ1
    - 6 low → IRQ7 (NMI)
    - 7 low → SN76494 write
  - Latch bits:
    - 7:6 MLC register select
    - 5 RTC read
    - 4 RTC CS2
  - T0 = not MLC IRQ. P2 input = 0xDF, T1 = 1.
- **MLC** (`bus/hp_hil/hp_hil.cpp:103-200`):
  - Reads:
    - 0 FIFO data
    - 1 FIFO high byte
    - 2 errors (PERR 1, FERR 2, FOF 4; clear on read)
    - 3 status (INT 1, NMI 2, LERR 4; clear on read)
  - Writes:
    - 0 sends a frame (address in W1 low 3 bits)
    - W1
    - W2 (IPF 4)
    - W3 (APE 2)
  - Devices:
    - 46021A ITF keyboard (`hlekbd.cpp`; IDD = layout 0xDF, 0x04).
    - 46060B mouse (`hlemouse.cpp`; IDD 0x68).
    - Command codes are in `hp_hil.h:33-59`.

## Other cards

**98265A SCSI** (`hp98265a.cpp`)
- Select code 14 = 0x6E0000, IRQ 4.
- Card registers:
  - w0 ID 0x07 / reset.
  - w1 ctl/status.
  - w2 SPC data / direct SCSI lines.
  - w3 reads 0x88.
- **MB87030 SPC** at +0x20-0x3F, odd bytes: BDID, SCTL, SCMD, TMOD, INTS, PSNS/SDGC, SSTS, SERR, PCTL, MBC, DREG, TEMP, TCH, TCM, TCL, EXBF (`machine/mb87030.cpp:54-69`). Clock 8 MHz.
- SPC DREQ goes to dmar0 or dmar1, selected by the DMA enables.
- Default devices: HDD at ID 0, CD at ID 5.

**98643 LAN** (`hp98643.cpp`)
- sc 21 = 0x750000, IRQ 5, full 64 KB window. Offsets within the window:

| Offset | Register |
|---|---|
| +0 | ID 0x15 |
| +2 | Status/ctl (IE 7, IP 6 inverted LANCE INT, lock 3, ack 2) |
| +0x4000 | Am7990 RDP |
| +0x4002 | Am7990 RAP |
| +0x8000-0xBFFF | 16 KB card RAM (LANCE DMA reaches only this) |
| +0xC000 | NOVRAM MAC address in low nibbles (08:00:09:...) |

**98644 serial** (`hp98644.cpp`)
- sc 9 = 0x690000.
- w0 ID 0x02.
- w1 ctl (bit 7).
- INS8250 at w8-15 (0x690011-01F), 2.4576 MHz.
- **MAME-GAP:** the IRQ is not wired.

**98620 DMA** (`hp98620.cpp`)
- 0x500000-0x50020F, 10 MHz clock.
- Legacy registers per channel at +0 and +8:
  - +0 addr hi (a read resets arm/IRQ)
  - +2 addr lo
  - +4 count
  - +6 ctl/status
- Ctl bits: 0 IE, 1 word, 2 out, 3 priority, 6:4 level − 3.
- **98620C extension:**
  - ID at +0x10/+0x12 = "20C0".
  - General ctl at +0x14.
  - 32-bit channel registers at +0x100/+0x200 (bit 8 long, bit 15 start).
- Transfer count = count + 1.
- **NetBSD `dma.c` requires it** for SCSI and HP-IB.

**98624 HP-IB:** sc 8, ID 0x01, TMS9914 at w8-15.

## Boot and OS requirements (inferred)

- **Boot ROM:** needs BERR on unmapped space, RAM at 0x5F4000, the PTM, the 8042, and a console (98550 ROM at 0x560000, or a 98644 at sc 9).
- **NetBSD/hp300:** needs SPC + 98620 + LANCE + 8042/HIL/RTC + PTM on IRQ6 + framebuffer or 98644.
- **HP-UX:** additionally uses HP-IB.
