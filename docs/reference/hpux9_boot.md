# HP-UX 9.1 kernel start-up: what it needs from the 385 core

This note covers the HP-UX 9.1 kernel (`/hp-ux` on `HP-OS-C2203.hpi`) from `_start` to the root mount. It was traced statically in the kernel binary, using the kernel's own symbol table and the kernel headers shipped on the same disk (`/etc/conf/machine/*.h`, `/etc/conf/graf.300/*.h`).

It answers three questions:

1. Why the kernel panics with a bus error at `0x20200007`.
2. How the console (ITE) driver waits for the Catseye window mover.
3. What else the kernel touches before it mounts root.

Tags:

- **[V]**: read from the code or the headers.
- **[I]**: inferred.
- **[X]**: checked against an outside source (NetBSD).

Addresses are kernel virtual addresses. Text starts at 0 and data at 0x111000 (see §5).

## 1. The crash: `Kernel bus error on address 0x20200007`, PC=0x98d46

### 1.1 Where it happens [V]

PC 0x98d46 is in `_YO_setup` (0x98cee-0x98d69). `_YO_setup` is called only from `_clkstart` (0x98c88), which `main` calls to start the PTM clock. `main` runs at IPL 6 until `spl0()` (called after `rootinit`), which is why the panic says IL=6.

```
_YO_setup:
098cee  tst.l   _YO_never           ; 0 in the shipped kernel
098cf4  bne     no_yo
098cf8  tst.l   _YO_always          ; 0
098cfe  bne     yo
098d02  cmpi.l  #3,_processor       ; 3 = M68040 (machine/cpu.h)
098d0c  bne     no_yo
yo:     ...                         ; make the vector page writable,
098d34  move.l  #_YO_handler,$78    ; level-6 autovector := _YO_handler
        ...                         ; write-protect it again, purge TLB
098d46  move.b  #$ff,$20200007      ; <-- bus error here
098d4e  move.l  #1,_YO_active
098d58  move.w  #$1309,D0           ; PTM timer-3 latch, returned to clkstart
        rts
no_yo:  clr.l   _YO_active
        move.w  #$13f9,D0
        rts
```

The faulting access is a plain byte write. There is no `testr`/`testw` probe wrapper and no bus-error catch around it, so the kernel expects hardware to be there. It is not a probe.

`_YO_never`, `_YO_always`, `_YO_active` and `_YO_count` are plain data words. Nothing else in the kernel references them; they are tunables meant to be patched with adb. With the shipped values, **every 68040 machine runs this code**.

### 1.2 Address mapping [V]

From `machine/cpu.h`:

```
LOGICAL_IO_BASE 0x20000000   PHYS_IO_BASE 0x00200000   INTIOPAGES 2048 (8 MB)
```

`_start` makes the mapping with `kmap_init(…, va=0x20000000, pa=0x200000, size=0x800000, prot=0x41)`. The prot value means cache-inhibited, serialized.

So physical = logical − 0x1FE00000:

- logical `0x20200007` → physical **`0x400007`**;
- `0x203F8000` → PTM at `0x5F8000`;
- `0x203F400E` → `0x5F400E`.

`_current_io_base` is set to 0x1FE00000.

### 1.3 What is at physical 0x400000 [V headers, I for +7]

`machine/eeprom.h` sets `EEPROM_REG_BASE_68K 0x400000` and `EEPROM_BASE_ADDR_68K 0x408000`. The register offsets it defines are:

| Offset | Meaning | Value |
|---|---|---|
| +1 | `EEPROM_ID_OFFSET` | reads 0 |
| +3 | `EEPROM_CONTROL_OFFSET` | write 0x53 to unlock; bit 4 = enabled |
| +5 | `EEPROM_SEC_ID_OFFSET` | reads 8; write 0xCC to unlock |

`machine/cpu.h` also places the "EEPROM hidden registers" at `0x400011`-`0x40003F` (odd bytes).

This is the same block the boot ROM's `eeprom_ctl_probe` looks for. The 380/385 carries the X2816 config EEPROM (see `SITE_NOTES.md`), so a real 385 has this controller.

Offset **+7 is not named in any header**. The only access to it in the whole kernel is the YO write above.

### 1.4 What YO does [V]

`clkstart` loads the value `_YO_setup` returns into the PTM timer-3 latch. It then sets CR3 = 0xC4: output enable, IRQ enable, **dual 8-bit mode**, external 250 kHz clock. In dual 8-bit mode the period is (MSB+1)×(LSB+1):

| Mode | Latch | Period | Rate |
|---|---|---|---|
| Normal | 0x13F9 | 20 × 250 = 5000 counts | 20 ms (HZ = 50) |
| YO | 0x1309 | 20 × 10 = 200 counts | 0.8 ms (1250 Hz) |

`_YO_handler` replaces the level-6 vector:

1. It tests PTM status bit 2 (timer 3).
2. It counts `_YO_count` down from 25 (0x19). On 24 of every 25 interrupts it acknowledges timer 3 with `tst.b` on the T3 MSB register and executes `rte`.
3. On the 25th interrupt it jumps to the normal `_Interrupt` path, which runs `_clkrupt`.

`_clkrupt` divides the timer-2 (O3-cascade) delta by 25 when `_YO_active` is set.

So the PTM input clock is unchanged at 250 kHz, and writing 0xFF to 0x400007 does not alter the clock. The system tick stays at 50 Hz. What the 1250 Hz level-6 interrupt is for, and what the 0xFF write enables, is not documented anywhere on the disk. [I] It is probably a board-level workaround on the 68040 machines.

### 1.5 What the core must do

**Acknowledge a byte write to physical 0x400007** (cache-inhibited, from supervisor mode) without a bus error. A latch that ignores the value is enough for HP-UX: nothing reads it back. Keep the rest of 0x400000-0x40FFFF bus-erroring unless the whole EEPROM controller is implemented:

- The boot ROM writes 0x400003 first (0x722) and reads 0x400001 first (`eeprom_ctl_probe`), both behind bus-error resumes. If those still bus-error, the ROM keeps its "no EEPROM" defaults, and its behaviour does not change.
- HP-UX probes the hidden registers 0x400011-0x40003F with `testr` (`hidden_mode_initialize`). Each register that answers is taken as a hidden-mode register for select code (value & 0x1F), and the SCSI and HP-IB drivers then use it. A stub that answers these reads would invent hidden-mode registers. Keep them bus-erroring.
- The cleanest decode is the **longword 0x400004-0x400007: writes are acknowledged and ignored, reads bus-error** (or return 0xFF; nothing reads them). Decoding a full EEPROM controller (ID 0 at +1, 8 at +5, unlock at +3/+5, data at 0x408001+2n) is the longer-term option, PLAN item 21. It changes the boot ROM's start-up path, because the ROM then reads the EEPROM.

The PTM model already supports dual 8-bit mode (`rtl/ptm6840.sv`), so YO timing works once the write is acknowledged. HP-UX will then take about 1250 level-6 interrupts per second.

**Confidence:**

- High: the location, the instruction, the VA→PA mapping, and the fact that this is not a probe.
- High: once 0x400007 acknowledges, the kernel gets past this point. The next steps are §3 and §4.
- Medium: that a real 385 acknowledges 0x400007. This is inferred: HP-UX 9 does the write unconditionally on every 68040, and the config-EEPROM controller lives in that block.
- Unknown: what the bit pattern does on real hardware.

### 1.6 MAME

MAME's `hp9k380_map` has nothing at 0x400000, so MAME would panic at the same write. It dies earlier, though, with `xbuserror: bus error before main entered`. Not traced. [I] The prime suspect is the 040 transparent translation:

- Before enabling the MMU, `_start` sets ITT1 = DTT1 = 0xFF00A000 (with 8 MB of RAM): 0xFF000000-0xFFFFFFFF, supervisor only, write-through. The kernel reads the boot ROM globals at 0xFFFFFxxx (`$fed2` sysflags, `$fedc` msus, `$fdce`) through it.
- In the 16 MB case the mask becomes 0xFF01A000.
- If MAME's 040 ignores the TT registers or their S field, those accesses fault before `main`.

## 2. Machine identification: 0x5F400E must carry the MMU ID

### 2.1 What the kernel reads [V]

`_start` (0xb1c) detects the CPU by writing CACR = 0x80000200. If bit 31 reads back, `_processor` = 3 (68040).

On the 040 path it then:

1. clears ITT0/1 and DTT0/1;
2. writes `move.b #7,$5F4003`;
3. records the FSAVE version;
4. writes `andi.w #$fffb / ori.w #4` to `$5F400E`;
5. reads **word `$5F400E` >> 8** (the byte at 0x5F400E) and indexes the table at 0xcbe.

| ID byte | `machine_model` | `uname -m` |
|---|---|---|
| 0 | 0xFFFF (unknown) | 9000/300 |
| 1 | 0x308 | 345 |
| **2** | **0x30A** | **385** |
| 3 | 0x309 | 380 |
| 4 / 5 / 6 / 7 | 0x30D / 0x30C / 0x310 / 0x30F | 43T / 42T / 43S / 42S |
| 8 / 9 | Woody | 425e/433e |
| 0xA / 0xB | Mace | 382 |
| > 0xD | 0xFFFF | |

[X] NetBSD `hp300spu.h` agrees: `MMUID_385 2`, `MMUID_382 11`, `MMUID_425_E 9`, and so on. NetBSD reads the long at 0x5F400C, shifts it right by 8 and masks with 0xFF, which is the same byte.

### 2.2 What the core does now

The core models `$5F4000` as 16 bytes of RAM. `_start` has already written `move.w #$64,$5F400E` at 0x986, so the ID byte reads 0 and `machine_model` = 0xFFFF.

This is not fatal. `machine_model` is used only for:

- the `uname` model string;
- `HAS_DIO_II` / the select-code scan range: 0x3F for 310/320, otherwise 0xFF;
- the SGC slot scan, 4xx only.

It should still be fixed.

### 2.3 What the core should do

Make the byte at **0x5F400E read-only 0x02** (385; 0x03 would mean 380). Keep 0x5F400F as a read/write control byte: the kernel writes 0x64 and 0x67 there and toggles bit 2 (cache clear) from `purge_dcache`.

The 040 kernel path never uses the HP-MMU registers:

- 0x5F4000/4: segment table pointers;
- 0x5F400A: TLB purge.

RAM behaviour is fine for those.

Confidence: high.

## 3. Console (ITE) driver for the 98550A: how it waits for the window mover

### 3.1 Which code path [V]

`crt_init` switches on the card's secondary ID (card ROM byte at +0x15 = 0x06 on the 98550A).

- IDs 5, 6, 7 and 9 (Catseye variants) get the `bobcat_*` routines with ITE flag **0x1000** ("Catseye") set.
- ID 2 (Topcat) gets the same routines without it.
- Flag 0x2000 (Fastcat daughterboard) is set only for a card above 0x20600000 whose `STATUS & 8` is clear. That never applies to the internal card at 0x560000.

### 3.2 The wait loop: `_bobcat_bmove_wait` (0xb2118) [V]

Every register-programming routine calls this first.

```
0b212a  move.l  ($1fc,A0),D0        ; ite flags
0b212e  andi.l  #$1000,D0           ; Catseye?
0b2134  beq     topcat_wait
0b2136  bftst   ($4801,A1){7:1}     ; A1 = card base (0x560000 phys)
0b213c  bne     $b2136              ; spin while set
```

For a Catseye this is the whole wait:

- **Register:** STATUS, byte offset 0x4800 (`CAT_STATUS (0x4800/2)` in `graf.300/ite_top.h`; core word index 0x400).
- **Bit:** bit 0 of the low byte at **0x564801**, which is bit 0 of the STATUS word. The header's struct gives it as `int :15, cat_wbusy:1;` at 0x4800. MAME's `catseye.h` agrees: "bit 0: 1 - window mover busy".
- **Loop:** spin while 1. There is no time-out.
- **Access size on our CPU:** offset 7, width 1 is a one-byte field. AP68040 (`S_BF_MEM0`) issues a **single byte read of 0x564801**. A real 040 may fetch differently, but the bit is the same.

The Topcat path (flag 0x1000 clear, unused here) reads word 0x409C (START_WMOVE, word 0x04E) and ANDs it with `planes<<8`. It spins with a growing delay while the result is non-zero.

### 3.3 Why the board drops characters

The core's STATUS read is `16'h000A | status | vblank`. Its bit 0 is never `wm_busy`. HP-UX therefore never waits, and it programs the next glyph while the mover is still running. Two things go wrong in `rtl/catseye.sv`:

- The mover reads `wm_sx`/`wm_sy`/`wm_dx` live (`sx = wm_sx + m_col`), so the new SOX/SOY/DOX corrupt the move in progress.
- `trig_topcat` is a one-clock pulse that is acted on only in `E_IDLE`, so a START_WMOVE written while busy is lost. That glyph is dropped.

With fast VRAM in the sim, each move finished before the next register write, which is why the text was perfect there.

### 3.4 What the core must do

**STATUS (word 0x400) bit 0 = `wm_busy`** for as long as a move started by START_WMOVE or by a T-register write is running. Both the low-byte read at 0x564801 and the word read at 0x564800 must see it. Keep the other STATUS bits:

| Bit | Meaning |
|---|---|
| 1 | ready |
| 3 | no daughterboard |
| 4 | vblank |

Also: [I] queue or latch a trigger that arrives while busy, as a safety net. HP-UX does not need it once bit 0 is right.

The ITE also waits on the Nereid colormap. `bobcat_init` spins on `bftst ($6003,A5){5:1}`, which is a byte read of 0x566003, bit 2 ("cmap_busy"). The core must keep that bit 0 or clear it promptly. It works today.

### 3.5 Exact access sequence for one run of glyphs (`_bobcat_write_off`, 0xb2538) [V]

Addresses are byte offsets from 0x560000; "w" is a word write. `planes` = `ite+0x128` (0xFF for 8 planes), so `planes<<8` = 0xFF00. Core word index = (offset − 0x4000) >> 1.

Once per call (a run of characters on one row):

1. `bobcat_write`:
   - **wait** (byte read 0x4801 until bit 0 = 0);
   - w 0x4088 TCWEN (0x044) = 0xFF00;
   - w 0x4090 FBEN (0x048) = planes<<8;
   - w 0x40EA PRR (0x075) = 0x0300.
2. w 0x4102 WWIDTH (0x081) = font width (`ite+0x8a`).
3. w 0x4106 WHEIGHT (0x083) = font height (`ite+0x8e`).
4. w 0x40FE DOY (0x07F) = row × font height.

For each character:

5. Look up the off-screen glyph position in `_offscreen_font[c]`: source x in the high word, source y in the low word.
6. If the attribute bits (`c & 0x7700`) changed since the previous character, which is always true for the first one:
   - **wait**;
   - then four passes, each "w 0x4088 TCWEN = mask, w 0x40EE WRR (0x077) = rule", with rules 0x0, 0x3, 0xC and 0xF; the masks come from the foreground/background plane sets;
   - then w 0x4088 TCWEN = 0xFF00.

   Otherwise: **wait**.
7. w 0x40F2 SOX (0x079) = glyph x.
8. w 0x40F6 SOY (0x07B) = glyph y.
9. w 0x40FA DOX (0x07D) = destination x.
10. w 0x409C START_WMOVE (0x04E) = planes<<8.
11. destination x += font width.

Other routines:

- **Scroll** (`bobcat_scroll`): wait; DOX=0, DOY, SOX=0, SOY, WWIDTH, WHEIGHT, TCWEN=FF00, WRR=3, START_WMOVE.
- **Clear** (`bobcat_clear` / `do_bobcat_clear`):
  1. wait;
  2. TCWEN/WRR pairs (rule 0xF for the background planes, 0x0 for the rest), then TCWEN=FF00;
  3. per rectangle: wait, then SOX, DOX, SOY, DOY, WWIDTH, WHEIGHT, START_WMOVE. Source = destination with a constant rule, so this is a fill.
- **Cursor** (`bobcat_cursor`): wait; TCWEN=FF00, PRR=0x600 (XOR), FBEN; then direct VRAM writes (`bitmap_cursor`).
- **Power-on reset** (`bobcat_pwr_reset`): wait, WRR=0, TCWEN=FF00, WHEIGHT=max(`ite+0x6c`, 0x200), SOX=DOX=SOY=DOY=0, WWIDTH=0x400, START_WMOVE=0xFF00, wait.

Confidence: high.

## 4. Root and swap device

### 4.1 Kernel side [V]

`/etc/conf/conf.c` (the configuration this kernel was built from) has:

- `rootdev = makedev(-1, 0xFFFFFF)`: root on the boot device;
- `swapdev1 = makedev(5,0)`: `swap1_strategy`;
- one `swdevt` entry `{SWDEF, 0, -1, 0}`: swap on the root disk, after the file system.

The dfile includes `scsi`, `cs80`, `hpib`, `98624`/`98625`/`98626`/`98642`, `lan01`, `cdfs` and others. Block major 7 and char major 47 are `scsi`; block major 0 and char major 4 are `cs80`.

`_scsi_init` (0xe7544) runs while the drivers are linked. It reads the boot ROM's MSUS at 0xFFFFFEDC-0xFFFFFEDF. If the device type (low 5 bits of 0xFFFFFEDC) is **0x0E (SCSI)** and `rootdev` is still −1, it sets:

```
rootdev = (7 << 24) | (sc << 16) | (target << 8) | (unit << 4) | volume
```

where sc is the byte at 0xFFFFFEDE, target the byte at 0xFFFFFEDF, and unit and volume the nibbles of 0xFFFFFEDD. For SCSI ID 0 on select code 14 that is **major 7, minor 0x0E0000**. `rootinit` prints it as "Root device major is 7, minor is 0xe0000".

The boot ROM fills in the MSUS when it boots from SCSI, so nothing in the core is needed here. The C2203 history does not matter to the kernel.

The SCSI driver's open sequence (`scsi_open`, `scsi_init_capacity`) uses:

- INQUIRY (0x12);
- TEST UNIT READY;
- READ CAPACITY (0x25);
- then the transfer commands from `scsi_xfer_cmd`.

MODE SENSE is sent only for TEAC floppies and from ioctls. All of these are in `docs/reference/scsi.md`. Swap size is taken as the disk capacity minus the file-system size: 670,666,752 bytes − 589,408 KB leaves about 64 MB.

### 4.2 User side: the installed system still names the HP-IB disk [V]

`/etc/checklist` contains one entry:

```
/dev/dsk/c7d0s0  /  hfs  defaults  0 1
```

`/dev/dsk/c7d0s0` is block major 0 (cs80), minor 0x070000 (HP-IB select code 7, address 0). `/dev/dsk` and `/dev/rdsk` hold only the `c7d0..7s0` cs80 nodes. There are **no SCSI nodes**. `/dev/root` and `/dev/rroot` are the special 0xFFFFFFFF nodes that the kernel maps to `rootdev`, so they work.

`/etc/inittab`:

- `initdefault` is 2;
- `brc1` runs `/etc/bcheckrc`.

`bcheckrc` runs `/etc/fsclean` over `/etc/checklist`. Opening `c7d0s0` fails, so `fsclean` returns 3 ("CHECK /etc/checklist FILE"). Then `fsck -P -F` fails as well, and bcheckrc starts **`/bin/sh` with prompt `(in bcheckrc)#`**. That is a usable root shell on the already-mounted root, which in practice is single-user mode.

To boot cleanly, run from that shell (or on a copy of the image):

```
mknod /dev/dsk/c14d0s0  b 7  0x0e0000
mknod /dev/rdsk/c14d0s0 c 47 0x0e0000
```

then point `/etc/checklist` at `/dev/dsk/c14d0s0`. Never write to `scratch/sw/HP-OS-C2203/x/HP-OS-C2203.hpi` itself.

Expect the networking scripts to complain: `lan01` is in the kernel, but there is no 98643 at select code 21.

Confidence:

- High: the kernel-side root device.
- High: the checklist and device-node mismatch.
- Medium: the exact bcheckrc path, which is read from the script and not run.

## 5. Everything else the kernel touches before the root mount

Order in `main` and `startup`. Every probe is `testr`/`testw` (bus-error protected) unless marked.

| What | Address (phys) | How | Core today |
|---|---|---|---|
| CPU ID, CACR | — | `movec` read-back of bit 31 | OK |
| System register | 0x5F400E word, 0x5F4003 byte | **unprotected** write/read; ID byte (§2) | RAM (ID byte wrong) |
| TT window | ITT1/DTT1 = 0xFF00A000 (8 MB) | kernel reads boot ROM globals at 0xFFFFFxxx through it | OK |
| MMU | 040 TC = 0x8000, URP/SRP; CACR = 0x80008000 | | OK |
| DMA | 0x500007 probe; **0x508007 must bus-error** (else "Must use a 98620B"); ID long at 0x500010 >> 8 = "20C" → 98620C | | OK (it printed 98620C) |
| Select-code scan | sc 0-31 at 0x600000+sc<<16; 0x33/0x36 (0x530000/0x560000); 0x3C (0x5C0000 "dragon" FPA); sc 5/6 → FRODO 0x41C000; sc 7 → 0x478000 unless sysflags bit 5; DIO-II 0x1000000+ (`machine_model` ≠ 310/320) | probed | OK |
| Parity / memory controller | 0x5B0001 (`testw`); if present, write 1 to 0x5B0000 | probed | bus error, fine |
| Hidden-mode registers | 0x400011-0x40003F | probed | **must stay bus error** (§1.5) |
| HIL | 0x428001/3 (`internal_hil_init`) | | OK |
| PTM | 0x5F8000: `snoozeinit`, `clkstart` (dual 8-bit, CR3 = 0xC4) | unprotected | OK |
| **YO** | **0x400007 byte write** | **unprotected** | **bus error → panic** (§1) |
| RTC | 0x420001/3: `inittodr` → `epson_present` sends 8042 commands 0x11 and 0xFE through the 8042 at base 0x418000+0x8000 | | OK (real 8042 firmware) |
| Root | SCSI sc 14, 98265A + 98620 DMA | §4 | OK |

The SCSI interface driver checks `hidden_mode_exists(14)` (`scsi_if_make_entry`, `scsi_fsm`, `scsi_if_set_tmod`). It finds none and uses the plain 98265A path.

`main` enables interrupts (`spl0`) right after `rootinit`, before `vfs_mountroot`. From then on, every pending device interrupt is live.

The LAN (`is_lan_sc`, sc 21) and the 98624/98625/98642 drivers find nothing and stay quiet.

**In short, the core needs exactly two changes to reach the root mount and the bcheckrc shell:**

1. Acknowledge writes to 0x400007 (§1.5).
2. Drive STATUS bit 0 from the window mover (§3.4), so the console stops dropping characters.

The ID byte at 0x5F400E (§2) is cosmetic but cheap.

## 6. How this was produced (tools in `scratch/hpux/`, not committed)

- **`tools/hfs.py`:** a read-only HFS reader.
  - The superblock is at byte 8192 of the image (magic 0x011954 at +0x55C), so the file system starts at offset 0, overlapping the LIF boot area.
  - Geometry: bsize 8192, fsize 1024, 82 cylinder groups, 2048 inodes per group, 128-byte inodes.
  - Directory entries are BSD variable-length entries.
  - Commands: `hfs.py IMAGE ls PATH`, `cat PATH OUT`, `tree PATH DIR`.
- **`tools/aout.py`:** parses the HP-UX s300 a.out header.
  - Header: magic 0x020C/0x0108, shared text. Text is 0x110DE8 bytes, loaded at 0. Data is 0x1E590 bytes at 0x111000. BSS is 0x26090 bytes. Entry is 0x972.
  - The symbol table follows the data. Each entry is `{value.l, type.b, namelen.b, almod.w, unit.w, name[namelen]}`, with no terminator; 5292 symbols.
- **`tools/kdis.py`:** runs `unidasm -arch m68040` per function and annotates absolute operands with symbols. `kdis.py all > hp-ux.lst` gives the full listing; `kdis.py SYMBOL` shows one function.
- **`tools/callgraph.py`:** a static call graph over `hp-ux.lst` (direct `bsr`/`jsr` only). `callgraph.py ROOT… -d DEPTH -t TARGET,…` prints the call paths from the roots to the targets.
- **`syshpux.bin` / `syshpux.lst`:** the LIF secondary loader (SYSHPUX, loaded at 0xFFFF0800). It loads the kernel at `$fdce` + the boot ROM global at `(A4)+$14`, rounded up to a page.
- **Extracted files:**
  - `hp-ux`, `text.bin`, `data.bin`, `hp-ux.syms`, `hp-ux.lst`;
  - `conf/`, a copy of `/etc/conf` with the kernel headers, `conf.c` and `dfile`.

## 7. The hang after "Networking memory for fragment reassembly…" (2026-10-15)

**Board symptom.** The I/O configuration prints, then `Networking memory for fragment reassembly is restricted to 671744 bytes`, then nothing for more than 90 s. There is no panic, and the cursor sits at the start of the next line.

The 671744 figure is consistent with 8 MB of RAM: `netmemmax` = 10 % of `maxmem` (about 1636 free pages after the kernel) [V].

### 7.1 What runs after that message, in order [V]

The message comes from `netmem_init`, called from `mbinit`. `main` calls `mbinit` through the `netproc[0x20]` hook, right after `clkstart` (the YO/PTM set-up of §1) and `cinit`.

`main` continues:

| Step | Call | Prints | Hardware |
|---|---|---|---|
| 1 | `netproc[0x20]` = `mbinit` → `netmem_init` | the networking-memory line | none |
| 2 | `netproc[0x30]` = `ntimo_init` | — | none (`kmalloc`) |
| 3 | `netproc[0x10]` = `ifinit` | — | none; loopback `if_init`, `if_slowtimo` → `net_timeout` → `timeout()` |
| 4 | `netproc[0x0c]` = `domaininit` | — | none; protocol `pr_init`s, `pffasttimo`/`pfslowtimo`, `nm_init` |
| 5 | `ihinit`, cdfs hook (`_cdfs_nop`), `bhinit` | — | none (`kmalloc`) |
| 6 | `binit` | — | none; buffer cache, `dbc_kdget`/`bfget`, page-table pages zeroed with `MOVE16` (`pg_zero*`) |
| 7 | **`printf("\nDisk Information:\n")`** | **the next line we should see** | console |
| 8 | `rootinit` | `    Root device major is 7, minor is 0xe0000, root site is 0` | the driver `dev_init` chain (`scsi_init` builds rootdev from the MSUS; no bus traffic) |
| 9 | `spl0()` | — | **first point where level 1-6 interrupts can be taken** |
| 10 | `bswinit`, `dnlc_init`, `msginit`, `seminit`, `shminit`, `privgrp_init`, `mounthashinit`, `find_root` | — | — |
| 11 | `vfs_mountroot` | (`mounting root fs RD_ONLY` only in the read-only case) | **first disk I/O**: INQUIRY, TEST UNIT READY, READ CAPACITY, superblock reads |
| 12 | `swapinit`, `dumpconf`, `init_kvm`, … | `    Swap device table: …`, `\nMemory Information:\n`, `    Physical: … Kbytes, lockable: …, available: …`, `    Using N buffers containing N Kbytes of memory.` | |
| 13 | fork `init` | `/etc/bcheckrc` output on the console | |

`_start` sets SR = 0x2600, and the first `spl0()` is step 9. Steps 1-8 therefore run at **IPL 6**. The panic in §1 confirms it (IL=6 inside `clkstart`).

The kernel `printf` is synchronous: `putchar` calls the console tty's output routine directly when `cons_up` is set.

### 7.2 Where it can be stuck

From step 1 to step 7:

- Nothing touches the SCSI card, the DMA controller or the disk.
- No interrupt of level 1-6 can be taken. The PTM/YO tick, the 98265A at level 4, the HIL at level 1 and the DMA at its programmed level are all masked.
- The only hardware these routines touch is the console (`printf`) and, through `purge_dcache`/`purge_tlb`, the 0x5F4000 block, which is RAM-like in the core.

So **none of the interrupt candidates (SCSI interrupt, DMA done, clock tick, HIL) can explain a stop before "Disk Information:"**. If the board really never shows "Disk Information:", the CPU is stuck in one of the following:

1. **A sleep in the memory allocator.** `kmalloc` → `alloc_reserve` → `sleep_then_unlock` → `sleep`, and `binit` → `dbc_kdget` → `allocpfd` → `sleep`. A sleep this early switches to the idle loop at IPL 0. The clock then runs, but nobody ever frees memory.
2. **A tight loop or a bus cycle that never terminates, at IPL 6.** Examples:
   - an instruction the CPU core gets wrong in `kmalloc`, `hdl_addtrans`, `vm_alloc_tables` or `pg_zero*` (`MOVE16 (xxx).L,(A0)+` from the zero line `gap_pgzero`);
   - an access the core decodes but never acknowledges.
3. **The console.**
   - The `\n` that starts "Disk Information" moves the cursor. `bobcat_cursor` polls STATUS bit 0 (§3); a mover stuck busy would spin forever.
   - A scroll happens only if the cursor is already on row 51. With about 15-20 kernel lines on a cleared screen it should not be.
   - Every glyph before this point waited on the same bit successfully, so this is the least likely of the three.

**How to tell 1 from 2 or 3, on the board without a rebuild.**

- HP-UX drives the 8 diagnostic LEDs (the latch at 0x1FFFF): `led_init` maps them, and `hardclock` calls `display_led_activity` → `update_leds`.
  - If the LEDs change while the console is frozen, clock interrupts are running: the kernel is asleep (case 1) or got past `spl0`.
  - If the LEDs stay at whatever the boot ROM or loader left, the clock never ran: the CPU is spinning at IPL 6 or stuck on a bus cycle (case 2 or 3).
- A second check: Caps Lock. The HIL driver lights the LED from its level-1 interrupt, which is masked at IPL 6.
- The next step is a PC sample: an OSD or debug readout of the CPU PC, or a Verilator run with `--vram-latency` set to the board's frame-buffer latency up to this point. The PC lands in one of the functions in the table above.

Confidence:

- High: the order of the calls and that the next expected line is "Disk Information:".
- High: no device interrupt can matter before step 9.
- Low: *which* of 1-3 it is. Static analysis cannot settle it; the LED check does.

### 7.3 The clock path against `rtl/ptm6840.sv` [V]

What HP-UX programs and reads (phys 0x5F8000, odd bytes; rs = (offset−1)/2):

| Who | Access | Meaning |
|---|---|---|
| `snoozeinit` | `movep.w $FFFF → +5/+7`; +3 = 1; +1 = 0 | T1 latch FFFF; CR2 bit 0 = 1 → CR1 = 0. T1 runs free on C1 (250 kHz), 16-bit, no IRQ. Used by `snooze()`/`get_4_usec_tick()`, which read the T1 counter with `movep.w +5/+7` (MSB, then the LSB buffer). |
| `snoozeinit` | `isrlink(clkrupt, 6, 0x5F8003, mask 0x80, value 0x80)` | The level-6 dispatcher reads the status register and needs bit 7 (composite IRQ). |
| `clkstart` | `movep.w $FFFF → +9` (T2 latch); +3 = 1, +1 = 0, +3 = 1, +1 = 0, +3 = 0, +1 = 0xC4 | CR2 ends 0x00: T2 on C2 = O3, 16-bit, no IRQ. CR3 = 0xC4: output on, IRQ on, **dual 8-bit**, external C3. T3 latch (`movep.w +D/+F`) = 0x1309 with YO, giving 1250 Hz. |
| `_YO_handler` (vector $78) | `btst #2,+3`; then `tst.b +D` | Status read with the T3 flag set, then a T3 MSB read, which clears the flag. 24 of 25 interrupts end with `rte`. |
| `_Interrupt` → `clkrupt` | status read (dispatcher); +3 = 0, +1 = 0x84; `movep.w +D` (T3); `movep.w +5` (T1); `movep.w +9` (T2); … +1 = 0xC4 | IRQ off while it runs. The T3 counter read clears the flag. T2 counts O3 periods; with YO the delta is divided by 25. IRQ back on at the end. |

`ptm6840.sv` implements all of this:

- rs map 1/3/5/…/F;
- status = {any_irq, 0000, flags};
- clearing the flag with a status read followed by a counter-MSB read (`flag_seen`);
- dual 8-bit timing (M+1)·(L+1);
- O3 → C2 falling edges;
- external clocks at 250 kHz;
- the CR1 internal reset.

**No mismatch found.** Once `spl0` runs, the clock interrupt should be delivered and cleared correctly. Level 6 = PTM in the core's priority encoder (`irq_lvl[6]`).

### 7.4 SCSI read path (98265A + MB87030 + 98620C), against the core

Card registers (phys 0x6E0000): +1 ID, +3 control, +7 configuration switches. SPC register *n* is at +0x21+2*n*:

| Offset | Register |
|---|---|
| +21 | BDID |
| +23 | SCTL |
| +25 | SCMD |
| +27 | TMOD |
| +29 | INTS |
| +2B | PSNS |
| +2D | SSTS |
| +2F | SERR |
| +31 | PCTL |
| +37 | TEMP |
| +39/+3B/+3D | TC high/mid/low |

**Set-up, once, from `kernel_initialize` → `scsi_if_init`, before the "Networking" line [V]:**

1. Level = ((+3 & 0x30) >> 4) + 3. The core returns 01 there, so the level is 4.
2. `isrlink(scsi_if_isr, 4, +3, mask 0xC0, value 0xC0)`: the card counts as interrupting only when **IE (bit 7) and "interrupt" (bit 6) are both set**.
3. `scsi_if_reset_bus`, in order:
   1. +3 = 0
   2. SCTL = 0
   3. SCMD = 0x10 (RST)
   4. `snooze(30)`
   5. SCTL = 0xC0
   6. SCMD = TMOD = PCTL = TEMP = TC = INTS = 0
   7. +3 = 0x80
   8. SCTL = 0x93 (| 0x08 if +7 bit 3 = parity)
   9. BDID = ~(+7) & 7
   10. SCTL &= 0x7F → 0x13/0x1B
4. `snooze(1 000 000)`: one second on the T1 counter.
5. If (+1 & 0x20) == 0, the kernel requires a 98620C (`dma_here` == 3) and sets "32-bit DMA OK"; otherwise it panics "Illegal SCSI configuration: no DMA". The core's ID 0x07 and DMA ID "20C" take the 32-bit path.

**Select (`scsi_if_select`):**

1. If SSTS & 0xE0, wait for bus free.
2. If INTS & 0x20, write INTS = 0x20.
3. PCTL = 0.
4. TEMP = (1<<target) | (1<<own ID).
5. Optionally SCMD = 0x60 (set ATN).
6. TCH/TCM/TCL = 3/0x0E/4 (selection time-out).
7. **SCMD = 0x20** (select).
8. Completion arrives as the level-4 interrupt.

**DMA read (`scsi_if_transfer`, case "DMA") [V]:**

1. `dma_build_chain`: one entry per physical 4 KB page, merged when contiguous.
   - Each entry's control is the driver's template: `scsi_if_dma_setup` → **0x41** = IE + level field 4. Then:
     - bit 2 (OUT) for writes;
     - bit 3 (PRI) when flags & 4;
     - **0x8100** (START + longword) when the buffer and count are 4-byte aligned on a 98620C;
     - bit 1 (word) for word mode.
   - Count = bytes/4 − 1 (or /2, /1).
   - **The last entry has IE cleared** (`dma_setup(…, 1)`).
2. SPC TC = byte count (24 bits); PCTL = PSNS & 7.
3. Card +3 = 0x80 | (read ? 0x04 : 0) | (32-bit ? 0x08 : 0) | (channel 0 ? 0x01 : 0x02).
4. **SCMD = 0x80** (transfer, DMA mode).
5. `dma_start`:
   - 32-bit: `move.l addr → 0x500100`, `move.l count → 0x500104`, `move.w ctrl → 0x500108` (START arms). Channel 1 uses +0x200.
   - Otherwise legacy: `move.l addr → +0`, `move.w count → +4`, **`move.b ctrl_lo → +7`** (arms).
6. **Between pages** the channel interrupts at **level 7**. In MAME's and the core's encoding, level = 3 + bits 6:4 = 7. That is deliberate: `_lev7int` is the chain engine.
   1. It tests DMA status +7 bit 1.
   2. It reads +0 with `tst.w`, which clears irq/armed.
   3. It writes the next entry's address, count and control (32-bit set at +0x100…, legacy at +0/+4/+6).
   4. It executes `rte`.
7. **End of transfer:** the SPC's "command complete" (INTS bit 4) raises card bit 6. With IE that is the level-4 interrupt, handled by `scsi_if_isr`:
   1. reads INTS, TEMP and SERR;
   2. **writes the INTS value back** to clear it;
   3. calls `scsi_if_dmaisr` → `dmaend_isr`. This reads DMA +0 (clear) and +4 (residual count; 0xFFFF = done), then sets +3 &= 0xFC (drop the DMA enables), reads the SPC TC residue, and clears +7 (`clr.b`).

**Comparison with `hp98265a.sv`, `hp98620.sv` and `mb87030.sv`:**

| Item | HP-UX expects | Core | Verdict |
|---|---|---|---|
| Card level / IE / IRQ bit | +3 bits 5:4 = level-3, bit 7 IE, bit 6 = SPC IRQ; IRQ only if IE | `{control[7], spc_irq, 2'd1, control[3:0]}`, `irq = control[7] && spc_irq`, level 4 | OK |
| DMA channel select | +3 bit 0 = channel 0, bit 1 = channel 1 | `dmar`/`de_ok` gated by control[1:0] | OK |
| +3 bits 2/3 (direction, 32-bit) | written | stored (mask 0x8F), no effect | OK: the core DMA moves bytes and counts units |
| +7 write (`clr.b`) | after each interrupt | ignored | OK as far as the driver needs |
| DMA level 7 for chaining | control 0x41 → level 7; `lev7int` re-arms | `irq_lvl[3 + ctrl[6:4]]`; level 7 edge re-armed in AP68040 (`nmi_arm`) | OK |
| DMA status / clear | +7 bit 1 = irq; read +0 clears | `{irq, armed}` at +6; read +0 clears irq and armed | OK |
| 98620C 32-bit registers | +0x100/+0x104 longs, +0x108 START | implemented; long writes split into words | OK |
| Residual count | +4 reads −1 (0xFFFF) when done | `tc` runs to −1 | OK |
| Legacy control written as a **byte** to +7 | low byte only | `10'h006: arm(…, reg_din)` ignores `reg_be`; the high byte comes in as 0 (the bus does not replicate bytes), so the longword bit is clear | harmless today; a merge with `reg_be` would be cleaner |
| **Bus reset release** | real MB87030: SCTL bit 7 (reset & disable) drops RST, so RST lasts about 30 µs | `mb87030.sv` releases RST only on an SCMD write while SCTL bit 7 is 0. HP-UX's SCMD = 0 comes while SCTL = 0xC0, so **RST stays asserted on the bus from `scsi_if_init` until the first selection's SCMD write**, and the targets sit in reset (`scsi_target`: `if (reset \|\| scsi_rst_i)`) | **mismatch** (medium). Fix: drop RST and clear SCMD/INTS state whenever SCTL bit 7 is set. Effect today: the first selection drops RST in the same write that starts arbitration, with the target leaving reset one clock later. Probably survivable, but not what real hardware does. |
| INTS bit 0 (bus reset seen) | handled; `+7 & 0x80` set gives the benign "Spurious RST" path | the core never sets INTS bit 0 | OK (no reset interrupt storm) |

None of these blocks the code before "Disk Information:". The RST mismatch is the one to fix before the root mount, because it is the first thing `vfs_mountroot`'s SCSI traffic meets.

## 8. The stop after "Networking memory ..." was a level-5 interrupt storm (found in sim, 2026-10-15)

The board build with the §1-§3 fixes stopped after `Networking memory for fragment reassembly is restricted to 671744 bytes`. A full-system sim of the same disk (fast SCSI selection time-out build, `--vram-latency 12`, the I/O event log on) showed what the static analysis could not:

- From about 440M clocks every PC sample was in `_Interrupt`, `_dio_IRQ`, `_splnet`, or the `ki_accum_*` interrupt accounting.
- The event log had 226,808 vector-29 (level 5) exceptions in about 80M clocks, against 7,517 normal level-6 clock interrupts.

How the storm comes about:
- **The driver init.** The 98626 driver had programmed the 8250 for 9600 baud (DLL 0x10), set IER = 0x0A (THRE and modem-status interrupts), and written the card's control word at +2 = 0x0080 (interrupt enable).
- **The dispatcher check.** `_dio_IRQ` claims a level-5 interrupt for the card only when the control byte (+3, a byte read) has bits 7 *and* 6 set. It read 0xA0 (enable and level 5, but no "interrupt requested" bit), so it never called the driver.
- **The result.** The 8250's interrupt was never serviced, and the level-triggered request re-entered at once.

The fix (`rtl/hp98644.sv`) is to make bit 6 follow the 8250's INTR in both bytes. MAME's 98644 leaves the interrupt unwired, so MAME never shows this. The 98265A already reports its bit 6 (`spc_irq`).
