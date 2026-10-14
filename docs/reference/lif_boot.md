# Booting from a LIF volume: what Boot ROM Rev 2.0 needs

This is how the HP 9000/380 Boot ROM Rev 2.0 (1818-5062) finds, lists, loads and starts a system from a LIF volume on a disk. It also covers the test image built from our own code (`scripts/mklif.py`, `tools/bootblk/`) and how to run it in the Verilator sim.

Everything here was traced in `docs/disasm/bootrom_rev2.0.asm` (addresses are ROM CPU addresses). NetBSD's `sys/arch/hp300/stand/mkboot` writes the same format and was used as a cross-check, but the ROM code is the authority. Tags: **[V]** read from the code (and, where noted, seen in the sim); **[I]** inferred.

## 1. Layers

The boot code talks to a disk through three small vector tables. Each one is chosen from the 32-bit *device code* in `($88,A4)` (A4 = the globals at 0xFFFFF702) [V]:

| Layer | Chosen by | Table | Vectors |
|---|---|---|---|
| Boot-device class (scan) | priority list at `($1c,A4)` / `($34,A4)` (entries `{prio.w, vec.l}`, e.g. 0x4012) | e.g. 0x5386 | +0 start a device scan, +4 find the next system on it (`loc_09572`, type 0xE942) |
| Volume format | bits 7:5 of the device code's top byte, list at `($28,A4)` = 0xE386 | 0x00 → 0xE3AE (**LIF**), 0x20 → 0xE3B6, 0x40 → 0xE3BE | +0 open (check the header), +4 find file |
| Device | bits 4:0 of the same byte, list at `($24,A4)` = 0xE414 | 0x0E/0x0F → 0xE4DC/0xE4F0 (**SCSI**, the read at 0x11980 checks card ID & 0x1F = 7) | +0xC open, +0x10 read(buf, len, sector256) |

The generic file layer at 0xE2DA dispatches `open` (0xEF7A), `find` (0xF024), `read` (0xF058), `close` (rts) to these [V].

**Sector units.** Every sector number the ROM uses for a volume is a **256-byte LIF sector**. The SCSI read (0x119AE) turns the sector into a byte offset (`asl.l #8`) and reads 512-byte blocks underneath, so LIF sector *s* is in SCSI block *s*/2 [V; in the sim, sector 0 → LBA 0, directory sector 2 → LBA 1].

## 2. Volume header (sector 0)

`open` (0xEF7A) opens the device, then reads 256 bytes of sector 0 into the buffer at 0xFFFFFDD2 and calls the LIF format's open (0xEBCA), which checks [V]:

| Offset | Field | Required |
|---|---|---|
| +0x00 | LIF id | **0x8000** |
| +0x08 | directory start (sectors) | copied to `($8c,A4)` |
| +0x0C | "System 3000" word | **0x1000** |
| +0x0E | | **0** |
| +0x10 | directory length (sectors) | copied to `($90,A4)` |
| +0x16 | | **0** |

The label (+0x02), version (+0x14) and the rest of the header are not looked at. Format 0x20 instead wants 0x0700 at +0 (0xED74), format 0x40 wants 0x3000 (0xEE8A); neither is LIF.

## 3. Directory

`find` (LIF: 0xEC30) reads the directory one 256-byte sector at a time (8 entries of 32 bytes), keeping its position in `($8c)` (sector), `($90)` (sectors left) and `($94)` (entry index), so repeated calls continue where the last one stopped [V].

| Offset | Field | Use |
|---|---|---|
| +0x00 | name[10], space padded | matched (below) |
| +0x0A | type | **0xFFFF ends the directory**, **0 = purged (skipped)**, otherwise compared |
| +0x0C | start sector | stored in `($98,A4)`: file-relative reads add it (0xF058) |
| +0x10 | length (sectors) | returned × 256 = length in **bytes** |
| +0x14 | date (6 BCD) | not used |
| +0x1A | flags | not used (mkboot writes 0x8001) |
| +0x1C | entry ("implementation") | returned as the **execution address** |

A match needs both:

- **Type 0xE942** (−5822). The scan (0x9584) and the loader (0x4162) both ask for it; only a caller passing −1 would accept any type.
- **Name.** `sub_0b35c` compares a Pascal-string pattern with the name (trailing spaces trimmed). A NUL in the pattern matches any rest of the name; otherwise the lengths must be equal. On a match the pattern is overwritten with the real name. The search pattern is `"SYS",0` (0x59B9, copied to 0xFFFFFDC2 at 0x970), so **every type-0xE942 file whose name starts with SYS is a system** [V].

## 4. Search, listing and auto-boot

After the self-tests the ROM prints "System Search Mode" (0xAAA) and walks the boot-device classes in priority order (0xB20). For each device it calls the class's scan routine and then "find next" until it fails (0xBA6 loop) [V].

- **Listing** (`sub_00d9c`, 0xD9C): each system is shown as *n L NAME*. **L** is the first character of the name that differs from `"SYSTEM_"` (0x59B1), or the character after it, upper-cased; anything not a letter becomes `Z`. So `SYSHPUX` → H, `SYSNBSD` → N, `SYSTEST` → S, `SYSTEM_A` → A. **n** counts systems already listed with the same letter, plus one.
- **Auto-boot** (0xBE0-0xBFE): when a system is found and `($b,A4)` bit 3 is clear, the ROM boots it **at once**: the first system found wins. Bit 3 is the "someone typed something" flag, set by the HIL/keyboard and serial input handlers (0x748C, 0x7526, 0x8144) and cleared when the keyboard is set up (0x72AC). With it set (attended mode, "Select System, type RETURN"), the ROM keeps scanning and boots what the user selects (`sub_00fd2` / `sub_00c14`; this path is [I]).
- With a selection stored (`$fdc0` ≠ 0, 0x97E) the ROM boots the stored name directly; if it is not found it prints "SYSTEM NOT FOUND" (0x9B8) and hangs.

## 5. Loading (`sub_040ea`, 0x40EA)

Called with (name, device code). It prints "Booting System" (0x4122), opens the volume (0x413C), finds the name with type 0xE942 (0x4172) and gets the length in bytes L and the entry address E. Then [V]:

The file is a list of **load records, each starting on a sector boundary**:

```
+0  load address  (long)
+4  byte count N  (long)
+8  data
```

```
D5 = 0                                   ; file-relative sector
repeat while (D5 + 1) * 256 <= L:
    read sector D5 into 0xFFFFFDD2       ; 256 bytes
    A3 = load address, D6 = N
    checks: A3 + N must not carry and must be <= 0xFFFFFAC0
                -> else "SYSTEM WOULD LOAD TOO HIGH", LED code 0x14
            if A3 + N > 0xFFFFF702 (the globals) and A3 < mem bottom ($fdce)
                -> "NOT ENOUGH MEMORY", LED code 0x15
    D5 += 1
    if N <= 248: copy N bytes from the buffer (+8)
    else:        copy 248 bytes, then read N - 248 bytes from sector D5
                 straight to A3 + 248;  D5 += ceil((N - 248) / 256)
```

(0x419C-0x424A.) The file-relative sector is offset by the directory start sector (0xF058). There is no check against the bottom of RAM and none against the ROM's own work areas: the ROM allocates from the bottom of RAM upward and from just below its globals (0xFFFFF702) downward (`($366,A4)`, 0xB3A4), so a load is safest well inside RAM. The test program loads at 0xFFF00000, 1 MB below the top of RAM.

Afterwards [V]:

- `$fdbc` (0xFFFFFDBC) = E; `$fedc` (0xFFFFFEDC) = the boot device code (NetBSD's `MSUS`), unless it was the "none" value 0xE0FFFFFF; `$fdc2` (0xFFFFFDC2) = the system name, 10 characters, space padded (0x4326-0x4382).
- `loc_04424` (also the fixed entry at **0x140**): clears 0x5F400E, enters supervisor mode with `TRAP #0`, sets IPL 7, clears the remote-console flag ($fed3 bit 1), re-initialises the console through `($4e,A4)` (on the 98550A that is `bitmap_console_init` 0x626E, which reruns the card's init tables), drains the serial console, optionally sends 8042 command 0x5F, and points every RAM exception slot from 0xFFFFFEE0 to 0xFFFFFFFF at `JSR 0x4F1E` ("UNEXPECTED USE OF *slot*", then halt).
- **Jump** (0x44E0-0x44E8): `A7 = 0xFFFFFDAC`, `D6.b = $fed2` (ROM flags), **`JSR (A0)` with A0 = E**. Other registers are left over from the ROM. If the system returns, the ROM continues at `probe_880000` (0x4DB6).

The ROM itself never jumps to the load address; only the directory's entry field counts.

## 6. Useful ROM entry points for a test program

The fixed `JMP` table at 0x120-0x1EB stays valid after boot as long as the globals at 0xFFFFF702 (and the pointer at 0xFFFFFED4) are left alone:

| Entry | Target | What it does |
|---|---|---|
| 0x140 | 0x4424 | the boot jump above (A0 = address) |
| 0x148 | 0x5E74 | reinitialise the graphics card and clear the frame buffer |
| **0x150** | 0x5ED6 | **print the NUL-terminated string at A0 at the start of text row D0.w** (0 = top row; the status line is the last row, `($80,A4)` rows in all). Saves D0-D1/A0-A1. It adds 1 to D0 and goes through the console slots `($5a,A4)` (cursor to column D0, row D1, both counted from 1) and `($54,A4)` (put character D0) [V, seen in the sim: D0 = 2 prints at y = 40 with the 98550A's 20-pixel font] |
| 0x13C | 0x5C14 | `grf_init_alpha` |

The LED latch is the byte at **0x1FFFF**: write the bitwise complement of the code (`docs/disasm/README.md` §1.4).

## 7. The image that `scripts/mklif.py` writes

```
sector 0 (byte 0)       volume header: 8000 "HP385 " dir=2 1000 0 dirlen ver=1 0, tracks/surfaces/sectors, date
sector 2 (byte 512)     directory: one 32-byte entry per file, then 0xFFFF entries to the end
sector 32 (byte 8192)   first file (each file starts on a 512-byte boundary)
```

A `--sys NAME:BINARY:LOAD[:ENTRY]` file is one load record: `{LOAD, N}` followed by the binary. N is rounded up to 248 + a multiple of 256 so that the ROM's second read is whole sectors (the extra bytes are zero and land after the program). The directory entry has type 0xE942, flags 0x8001 and the entry address (default LOAD). This is the same layout as NetBSD `mkboot` (LIF_DIRSTART 512, LIF_FILESTART 8192, one `struct load` header).

## 8. The test program (`tools/bootblk/test.s`)

Loaded and entered at 0xFFF00000, named `SYSTEST` (listed as "1S SYSTEST"). It:

1. writes LED code **0x5A** (latch byte 0xA5);
2. draws into the 98550A frame buffer (0x200000, 1 byte per pixel, 2048-byte stride): a solid bar of colour 0xFF on rows 704-735, colour 0x01 on rows 752-783, and 64-pixel 0xFF/0x00 stripes on rows 800-863;
3. prints two lines through entry 0x150 (text rows 2 and 3);
4. with `TAILTEST=1` (the default) checks a magic long at the end of the 1.5 KB image, which only arrives if the ROM's multi-sector read worked. `TAILTEST=0 tools/bootblk/build.sh` builds a 216-byte variant that fits in the first sector, so the ROM loads it with programmed I/O alone;
5. writes LED code **0xA5** (latch 0x5A) and loops. A bad tail gives LED code 0xEE (latch 0x11) and an error line instead.

## 9. Building and running

```sh
tools/bootblk/build.sh            # -> build/hp385_testboot.img (64 MB), build/bootblk/test.{bin,lst}

cd verilator
./obj_dir/Vhp385_top --rom out/bootrom_fast.bin \
    --card-rom ../scratch/roms/dio98550/98550a.bin \
    --hil-rom ../scratch/roms/human_interface/1820-4784.bin \
    --disk0 ../build/hp385_testboot.img \
    --cycles 200000000 --status 0 --loop-window 0 \
    --log /tmp/events.log --snap /tmp/screen.ppm
grep -a 'LED  ..$\|DISK0' /tmp/events.log
pnmtopng /tmp/screen.ppm > /tmp/screen.png
```

`--disk0` is SCSI ID 0 on the 98265A at select code 14. The ROM scans the SCSI IDs from 6 down to 0, and each empty ID costs a selection time-out, so ID 0 is reached late. The sim writes any disk writes back into the image file.

## 10. Result in the sim (2026-10-14)

Both runs used the command in section 9 with the core built at that date.

**`TAILTEST=0` (one-sector image): boots and runs.**

| Clock | Event |
|---|---|
| 108.6M / 109.1M | scan of SCSI ID 0: READ(10) LBA 0 (volume header), LBA 1 (directory) |
| | the screen lists `:HP9K385 SCSI DISK, 1400, 0` and `1S SYSTEST`, then "Booting System" (no key pressed, so the first system is booted) |
| 113.5M-114.5M | boot: LBA 0, LBA 1, LBA 16 (the load record) |
| 129.2M | raw LED 0xA5 (code 0x5A) at pc 0xFFF00004: the program is running |
| 131.6M | raw LED 0x5A (code 0xA5) at pc 0xFFF0006A; stopped at the `bra *` (0xFFF00072) |

The ~15M clocks between the load and the first instruction are the console re-initialisation before the jump, which clears the screen. The screenshot shows the two text lines on rows 2-3 and the three bars at y = 704, 752 and 800 (colours 0xFF and 0x01 both show as white with the ROM's colour map).

**`TAILTEST=1` (1.5 KB image): hangs in the ROM's SCSI driver; a core bug, not the image.** Sequence:

- Scan and boot reads as above, then LBA 16 again (programmed I/O, the second half of the block = file sector 1) and READ(10) LBA 17 count 2 through the **98620 DMA**: channel 0 address 0xFFF001F8, count 0xFF (256 longwords), control 0x810A; SPC transfer count 0x400, SCMD 0x80. The SPC reports command complete (INTS 0x10) at 115.48M with its transfer count at 0.
- The ROM (`sub_13094`, 0x13094-0x1314E, called from 0x1410C) then waits for the DMA count register (`move.l 0x500104`) to equal *(SPC residue / 4) − 1* = **0xFFFFFFFF**. Our `rtl/hp98620.sv` leaves the count at **0x00000000** after the last unit, so the ROM polls for its 1 s time-out (115.48M → 148.48M), records a failure (`sub_12b84(8)`, 0x14120), and goes into error recovery.
- MAME's `hp98620.cpp` (`dma_transfer`: `if (m_regs[channel].tc-- == 0)`) post-decrements, so its count does end at 0xFFFFFFFF. In `rtl/hp98620.sv`, task `count`, the `tc[n] == 0` branch disarms without decrementing; it should also do `tc[n] <= tc[n] - 1`.
- Error recovery then hangs for good: in STATUS the ROM sets ATN (SCMD 0x60) before releasing ACK, and in MESSAGE IN it sets ATN and issues a padded program transfer with TC = 0 (SCMD 0x85, 0x135C8-0x135D6). PSNS never shows ATN (0x8F, then 0x4F). [I] The likely cause is that `rtl/scsi/mb87030.sv` (like MAME) only latches "set ATN" for the next selection while its command state machine is idle, which it is between manual handshakes. The disk never goes to MESSAGE OUT, ACK stays held on the COMMAND COMPLETE byte, and the ROM polls PSNS/INTS at 0x1366C/0x13680 forever (PSNS 0x4F, INTS 0). This path only runs after an error, so it is secondary; whether a real MB87030 asserts ATN in that state needs the data sheet.
