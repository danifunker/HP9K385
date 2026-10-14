# hp-series300.net — scraped notes relevant to a Model 385 core

Mirror: `scratch/site/hp-series300.net/` (6 HTML pages, 13 PDFs, 25 photos).
Plain-text conversions of every page/PDF: `scratch/text/`.

## Model 380 / 385 facts

| Item | Value | Source |
|---|---|---|
| CPU | MC68040, 33 MHz (385) / 25 MHz (380). Internal FPU + MMU | processors.pdf |
| Processor board | 98574-66510 (photo) / 98574-59511 (385 exchange part); same board as 375 and 380 | processors.pdf, 385_upgrade.pdf |
| Clock | 66 MHz oscillator, CPU runs at exactly half (PCLK=66, BCLK=33) | 385_upgrade.pdf |
| 25/33 jumper | 33 MHz setting adds a RAM wait state so each bank is hit no more often than every 3rd clock (90 ns) | setup.htm |
| RAM | 8 MB std / 128 MB max; plug-in RAM boards, pairs interleaved on alternate clocks; 80 ns DRAM; 40 ns read cycle quoted for 380 | processors.pdf, hardware.htm |
| Performance | 380: 22 MIPS / 2.2–2.6 MFLOP; 385: 29 MIPS / 2.9–3.5 MFLOP | processors.pdf, hardware.htm |
| Boot ROM | Revision **2.0** required (68040 support, SCSI CD-ROM boot). 1 Mbit OTP EPROM, Intel N27C210 (64K x 16 = 128 KB), PLCC-44. Image on Bitsavers | setup.htm, software.htm |
| Config EEPROM | 16 Kbit Xicor X2816B (2 KB). Contents on Bitsavers. Rev D+ ROMs use it to store default boot device etc. | setup.htm, software.htm |
| Slots | Double-height CPU board + separate video board, one free full-height DIO-II slot | hardware.htm |
| Built-in I/O (late models) | HP-IB, RS-232 (98644-compatible), HP-HIL, parallel printer port, SCSI-1 (= 98658A / 98265A, 50-pin), LAN (= 98643A, Am7990 LANCE, AUI + BNC) | hardware.htm, Interface_boards.pdf |
| 40 MHz | 68040RC40 works for BASIC/WS but flaky under HP-UX (RAM timing) | setup.htm |

## Graphics: HP 98550A ("Catseye")

- 1280 x 1024, 256 colours (8 bpp) from a 24-bit colour map, 60 Hz, 63.3 kHz HSR.
- 8 image planes **plus two overlay planes** (Starbase only).
- Optional 98556A 2D accelerator daughterboard (the only 300-series board with real acceleration).
- Text: 128 x 51 chars with 10x20 glyphs, 32 px left/right margin, 4 px top margin.
- Boards carry 0.5/1/2 MB VRAM with off-screen area for font glyphs (loaded from the card's ROM at boot) and hardware window-move (block mover).
- Monitors: 98789A 16", 98752A/98754A 19". Composite sync-on-green RGB.
- HP-UX `TERM=hp98550a`.

## Software targets for the 385

| OS | Version | Notes |
|---|---|---|
| HP BASIC/WS | 6.2+ (6.4 last, Y2K-fixed) | 6.2 added 380/382 + SCSI + parallel |
| BASIC PLUS | 6.33 | extension to BASIC/WS |
| Pascal Workstation | **3.25** | first to explicitly support 385 (68040 FPU @ 33 MHz) |
| HP-UX | 9.0 / 9.10 | needs 8 MB console, 16 MB for X/VUE; install from SCSI CD (512 B sectors) |
| NetBSD | 9.2+ (current still ships hp300) | FPU + ≥4 MB; disk `sd5` on first SCSI |
| OpenBSD | 5.5 (last hp300) | ≥12 MB RAM |

Boot ROM only reads LIF volumes; BSD bootstraps hide in a LIF wrapper in the disklabel area.
Default select codes seen in docs: HP-IB = 7, SCSI = 14 (second SCSI 15), internal HIL/serial at fixed internal codes.

## Mass storage implications
- SCSI is the practical path for a MiSTer core (SD-card-backed disk + 512 B-sector CD-ROM image). HP-IB (CS/80 disc via TMS9914) is optional — needed only for the classic HPDrive `.hpi` images.
- Max bootable disk 2 GB.

## Other docs in the mirror
- `HP-HIL_connectors.pdf` — HIL pinouts.
- `monitors.pdf` — scan rates per board (98550A = 63.3 kHz).
- `Install_*.pdf`, `NetBSD-INSTALL.txt`, `OpenBSD-INSTALL.txt` — install procedures; good acceptance tests.
- `BasicPlusDoc.pdf` — BASIC PLUS manual.
