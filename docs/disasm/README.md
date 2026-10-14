# Firmware disassemblies: boot ROM Rev 2.0, 98550A card ROM, 8042 HIL firmware

This directory holds annotated listings of the three HP firmware images used by the core, plus the scripts that regenerate them.

| File | Contents |
|---|---|
| `bootrom_rev2.0.asm` | HP 9000/380 boot ROM Rev 2.0 (1818-5062), 68040, 128 KB. About 109 KB is classified as code (30,400 instructions). |
| `98550a.asm` | HP 98550A Catseye card ROM (32 KB). It contains no 68k code: the listing decodes the header, the init tables, the font directory and both fonts (as bitmaps). |
| `8042_1820-4784.asm` | HP human-interface 8042 (UPI-42) firmware (2 KB). |
| `tools/` | Generators and helpers (see *Regenerating*), including `bootrom_simpatch.py`, which builds the sim-only fast-boot ROM. |

Evidence tags used below:

- **[V] verified.** Read directly from the code, or checked by computation.
- **[I] inferred.** A reasonable interpretation that has not been confirmed by running the code.

The ROM images themselves are not in git (see `docs/ROMS.md`). The listings contain the full disassembly and data, so treat them like the ROMs: keep them out of public places unless that is acceptable.

---

## Regenerating

Tools used:

- `unidasm` from Debian `mame-tools` 0.285+dfsg1-1 (MAME's universal disassembler). Arch `m68040` was used for the boot ROM and `upi41` for the 8042. `upi41` is the UPI-41/42 variant of MCS-48, which knows `IN A,DBB`, `OUT DBB,A`, `MOV STS,A`, `EN FLAGS`, `JOBF` and `JNIBF`.
- Python 3.14.4, always run as `python3 -I -B` (isolated mode, no `__pycache__`).

```sh
cd <repo root>
python3 -I -B docs/disasm/tools/gen_bootrom.py scratch/roms/hp9k380/bootrom_be.bin docs/disasm/bootrom_rev2.0.asm
python3 -I -B docs/disasm/tools/gen_98550a.py  scratch/roms/dio98550/98550a.bin    docs/disasm/98550a.asm
python3 -I -B docs/disasm/tools/gen_8042.py    scratch/roms/human_interface/1820-4784.bin docs/disasm/8042_1820-4784.asm
# sim-only fast-boot ROM (writes a new file; the input is never modified):
python3 -I -B docs/disasm/tools/bootrom_simpatch.py scratch/roms/hp9k380/bootrom_be.bin /tmp/bootrom_fast_be.bin [--ramsize-base 0xFF800000]
```

`gen_bootrom.py` also accepts the raw MAME little-endian-word file and swaps it automatically. Each run takes about 15 s, because unidasm is called per code window.

### Input images

| Image | SHA1 | Notes |
|---|---|---|
| `1818-5062_98754_9000-380_27c210.bin` (MAME, LE words) | 4c0a3929e45202a2689e353657e5c4b58ff9a1fd | matches `docs/ROMS.md` |
| `bootrom_be.bin` (byte-swapped CPU view) | 6c57648432fc9cbd39021a707f469c7538b7d8b0 | used for the listing |
| `98550a.bin` | d6b23a34850f24525ca5fb36de3deb91196d2dc5 | matches `docs/ROMS.md` |
| `1820-4784.bin` | 90849a10bdb8c6e38e73ce027c9c0ad8b3956b1b | matches `docs/ROMS.md` |

### Byte order and odd-byte handling

- **Boot ROM.** Every 16-bit word of the MAME file is byte-swapped. The listing addresses are CPU addresses from 0x00000000. [V] After the swap, the reset vectors are SSP 0x100 and PC 0x418.
- **98550A ROM.** The file is a byte stream. File byte *n* appears on the bus at **0x560000 + 2n + 1**, and even bus addresses read 0xFF. Every offset stored *inside* the card ROM is a **bus offset from 0x560000**, so a stored value V means file byte (V−1)/2. The boot ROM reads multi-byte fields with `MOVEP`, which takes consecutive file bytes, big-endian. The listing shows both the file offset and the bus address on every line. [V]
- **8042.** A plain MCS-48 image at 0x000-0x7FF.

### How the 68k listing was produced

`tools/m68kdis.py` drives unidasm as a recursive-descent disassembler. Decoding an address is context-free, so the decoder caches instructions by address.

1. **Starting points.** The flow is followed from:
   - the reset and bus-error vectors;
   - the warm entries at 0x400, 0x40A and 0x40E;
   - the fixed-address `JMP (d16,PC)` entry table at 0x120-0x1EB;
   - the four self-test step tables;
   - the extension-hook pointer table at 0x1E742.
2. **Extra code references recognised:**
   - Pre-RAM "register calls": `lea ret(PC),A4/A6`.
   - Bus-error resume addresses: `lea x(PC),A6`.
   - HP Pascal `TRY` handlers: `pea x(PC)`.
   - Procedure pointers: `lea/pea x(PC)`, `pea x.l`, and `move.l #x,<mem>`, accepted only when the target decodes cleanly.
   - HP Pascal `CASE` tables: `move.w (d,PC,Dn),Dm ; jmp (d,PC,Dm)`. 42 were found and rendered as `dc.w target-base`.
3. **Terminators.** `TRAP #10` (HP Pascal `ESCAPE`) is treated as non-returning.
4. **Gap scan.** The remaining gaps were scanned for code starts:
   - gap starts that decode to a terminated instruction run;
   - `LINK A6` prologues;
   - `MOVEA.L (A7)+,A0` and `MOVEM` prologues;
   - words after an `RTS`.

   Code found only this way is labelled `h_xxxxx`. Most of it is reached through RAM JMP slots or procedure variables.
5. **Data.** Everything else is rendered as data: strings as `dc.b "..."`, tables as `dc.l`/`dc.w`, and fill as `dcb.b`.
6. **Hardware comments.**
   - Absolute addresses in operands are named from `tools/hp300map.py`, which follows `docs/reference/mame-hp380.md`.
   - Accesses through an address register loaded with a constant earlier in the same basic block are tagged `~addr name`. These are inferred.
   - Manual names and comments live in `tools/bootrom_notes.py`.

Remaining imperfections:

- A few small structures that mix records and code (menus near 0x1A11C-0x1A50C) are partly shown as data.
- Three decode conflicts are harmless:
  - 0x1EA8 is the "target" of an `FNOP`.
  - 0xA228 and 0xF7AA are case-table artefacts.

---

## 1. Boot ROM Rev 2.0: summary

### 1.1 Layout [V]

| Range | Contents |
|---|---|
| 0x00000-0x0011F | Exception vectors 0-71. Only vector 1 (reset → 0x418) and vector 2 (bus error → 0x4D3A) point into ROM. All others point to 6-byte `JMP abs.l` slots in RAM at 0xFFFFFE..-0xFFFFFF.., which the ROM fills at run time (0x1B24, `step_4990`). |
| 0x00120-0x001EB | Fixed entry table, `JMP (d16,PC)` × 49. 0x154 and 0x1B0 are data pointers, to the keyboard tables at 0x6CC2 and to 0x4EC4. |
| 0x001EC-0x003FF | Two longs (0x00808000, 0x00801D7C), then vectors 125-255 → RAM slots 0xFFFFF400 + 6n. |
| 0x00400-0x00417 | Warm entries. |
| 0x00418- | Reset code, then the self-test framework and the drivers. Mostly HP-Pascal-compiled code from about 0x8000. |
| 0x02742-0x02FFF | 0xFF fill. |
| 0x03000-0x03ED7 | Pascal-runtime numeric tables (BCD and similar). |
| 0x03FD0 | `"BOOTROM  Rev. 2.0  29 NOV 90"` |
| 0x0556C-0x05C13 | Main string table, including the card-ID → name table at 0x5A59. |
| 0x1E73E | This ROM's own extension-hook table. The pointer to it is at 0x1FFF0. |
| 0x1FFFC-0x1FFFF | Checksum adjust long (0x3558BBFD). This is also the LED latch address for writes. |

**RAM conventions:**

- **Globals base.** A4 = **0xFFFFF702**, also stored at 0xFFFFFED4.
- **Stack.** 0xFFFFFDAC once RAM is known good.
- **Absolute-short globals at 0xFFFFFxxx**, written `$xxxx.w` and sign-extended:

| Global | Meaning |
|---|---|
| `$fdce` | lowest RAM address found by sizing |
| `$fdd2` | register save area / string buffer |
| `$feda` | CPU flags: b0 = upper 128K ROM present, b2 = has data cache, b3 = 68020/030 (0 means 68040), b6 = no config EEPROM |
| `$fed9` | test mode (bits 7:6) |
| `$fedb` | EEPROM configuration byte |

### 1.2 Reset path [V]

| Addr | What happens |
|---|---|
| 0x418 | `MOVEM.L D0-A7,$FFFFFDD2` saves the registers into top-of-RAM scratch (RAM always ends at 0xFFFFFFFF). A7 = 0. |
| 0x422-0x45C | Register-file test with patterns 0, 0x55555555 and 0xAAAAAAAA. On failure the LED latch gets **0xFE** and the CPU executes `STOP #$2700`. |
| 0x46A | Boot flags: **D5 = 2** (bit 1 = run the RAM test) and D6 = 0x2A. A warm entry with D5 bit 3 set copies the flags back from the old globals. |
| 0x490 | **A7 = 0x200.** This is the "no RAM yet" mode for the bus-error handler (see 1.3). |
| 0x49E-0x4AA | Probe 0x41C0C0 (the FRODO service switch on 4xx). On a 380 it bus-errors and execution resumes at 0x4AE. |
| 0x4AE-0x4D4 | Fill 0xFFFFC000-0xFFFFFFFF with 0xEEEE1111 (parity/ECC init of the top 16 KB). |
| 0x4D6-0x4E6 | `TST.B` one byte every 64 KB from 0xFFFFFFFF down towards 0x20000000. The first bus error ends the loop. The result is discarded. |
| 0x4E8-0x504 | **Lamp test**: the raw latch walks 0x80, C0, E0, F0, F8, FC, FE, FF, each step a 65536-pass delay loop. Afterwards D7.w = 0x7FFF, which enables the raw LED writes that follow. |
| 0x506-0x5BE | Probe the 3xx alpha video at 0x51xxxx. Not on a 380: it bus-errors. |
| 0x5C2 | Raw latch **0xFD**. |
| 0x5D0-0x6E6 | Pattern test of the top 16 KB (0xFFFFC000-0xFFFFFFFF), routine 0x610. On failure: raw **0xFC** "RAM FAILED ABOVE FFFFC000" or **0xFB** "RAM GONE ABOVE FFFFC000", then `STOP`. |
| 0x6E8 | Globals at 0xFFFFF702. Flags are stored into ($a,A4), ($b,A4), $fed2. |
| 0x722-0x748 | Pokes 0x400003/5/B/1 (EEPROM controller) and 0x880000. Both are protected against bus errors. |
| 0x794 | Stack moves to RAM (0xFFFFFDAC). |
| 0x798 | `install_buserr_resume`: RAM slot 0xFFFFFFFA = `JMP 0x4D5C`. |
| 0x79C | `sysreg_5f400e_clear` (see 1.7). |
| 0x7A2-0x7A6 | 0x6CC sets $fed9 bit 2. It is cleared only when the 4xx service switch is on; on a 380 the probe bus-errors and the bit stays set. Then `cpu_detect` (0x131C). |
| 0x7AE / 0x7B2 | **PTM init and "is it counting" check**, LED code 0x20. If the PTM is missing or not counting, the CPU halts with LED 0x20. |
| 0x7B6-0x7D4 | Config EEPROM probe (0x1ABC0). EEPROM check, detection of an upper 128K ROM at 0x20000 (0x1E70E), then EEPROM item 3 is read into $fedb. |
| 0x7F2-0x84A | Pick the test mode and the self-test step table (1.5). |
| 0x884 | 0xE2EE. LED 0x21 (0x894) only when the EEPROM is present. |
| 0x8AC | LED **0x05**: ROM-extension scan from 0x20000 to 0x3FFFFF in 16K steps. A header is the word 0xF0FF. LED **0x06** marks each extension found before its init is called. |
| 0x926 | `run_selftest_steps` (0x1236), LED **0x07**. |
| 0x92A | After the tests: Configuration Mode / system search and boot. This part was not analysed in detail. |

### 1.3 Bus errors and probing [V]

The bus-error handler is vector 2, at 0x4D3A:

- **A7 > 0x200** (RAM exists): `JMP $FFFFFFFA`, the RAM slot. Normally this is `JMP 0x4D5C`, which calls `buserr_frame_cleanup` (0x13EC) and then `JMP (A6)`.
- **0x100 < A7 ≤ 0x200** (before RAM): A7 = 0x200, then `JMP (A6)`.
- **A7 ≤ 0x100**: A7 = 0x100, then restart at 0x41E.

So every probe is `LEA resume(PC),A6` followed by the access.

`buserr_frame_cleanup` (0x13EC) reads the frame format:

- For a 68040 **format-7** access-error frame it performs the pending write-backs WB2/WB3 (0x1464).
- It then removes the frame, using the size table at 0x14A0.

Install points for the RAM slot:

- 0x4D64 / 0x4D7A install `JMP 0x4D5C`.
- 0x4DB6 temporarily installs `JMP 0x4DEE` for the 0x880000 probe.

**Consequences for the core:**

- Unmapped space must assert BERR quickly. The ROM probes all of the following:
  - 0x41C0C0
  - 0x400001-0x40000B and 0x408000+ (EEPROM)
  - 0x880000
  - 0x510000-0x51FFFF, 0x516000, 0x520000/0x538000/0x540000 (3xx alpha/bitmap video)
  - 0x5B0000
  - 0x5D0001 (98286)
  - 0x300000xx
  - 0x3FFF0 and 0x20000-0x3FFFFF (upper ROM / ROM extensions)
  - DIO-I select codes 0-31
  - DIO-II 0x1000000-0x1FFFFFFF in 4 MB steps
  - 0x500000 and 0x508000 (DMA)
  - 0x478003 (HP-IB)
  - everything below the bottom of RAM
- **Before RAM exists, the 040 pushes its bus-error frame into ROM space (A7 ≈ 0x1C4-0x200). These writes must be ignored and must not bus-error.** Only 0x1FFFC-0x1FFFF is the LED latch. MAME's `led_w` takes the whole ROM range, so in MAME these frame writes also hit the LEDs.
- The ROM uses the **8042 mirror at 0x428001 / 0x428003**, not 0x420001.

### 1.4 LED codes [V]

The LED latch is the byte at **0x1FFFF**. `set_led(code)` at **0x4FAC** stores `code` in ($c8,A4) and writes **~code** to the latch. The table lists *codes*; for raw writes it gives the raw latch byte and the code it equals.

**Raw writes before `set_led` exists:**

| Raw latch | Code | Where | Meaning |
|---|---|---|---|
| 0xFE | 0x01 | 0x45E | CPU register test failed. Halt. |
| 0x80→0xFF | — | 0x4F0 | Lamp test. |
| 0xFD | 0x02 | 0x5CA | Top-16K RAM test running. |
| 0xFC | 0x03 | 0x6A2 (from 0x674) | "RAM FAILED ABOVE FFFFC000". Halt. |
| 0xFB | 0x04 | 0x6A2 (from 0x698) | "RAM GONE ABOVE FFFFC000". Halt. |

**`set_led` codes in execution order** (default 380 path: no EEPROM, mode 2 / table 0x1128):

| Code | Writer | Meaning |
|---|---|---|
| 0x20 | 0x136C `ptm_init_led20`, 0x13B4 `ptm_check_running` | PTM init and "is it counting". A **halt with 0x20** means the PTM is missing or stopped. |
| 0x21 | 0x894 | EEPROM-related step (only if the EEPROM controller is present). |
| 0x05 | 0x8AC | ROM-extension scan. |
| 0x06 | 0x910 | Extension found; calling its init. |
| 0x07 | 0x1240 | Self-test step executor. |
| 0x08 | 0x14CC step 31000 | 8042 command 0x31, `RESET` instruction, PTM re-init. |
| 0x09 | 0x151A step 27000 | Console search starts. |
| 0x0A | 0x15A6 / 0x16F8 | Test the RAM area for a card-ROM 68k module. |
| 0x0B | 0x15D6 / 0x171E | Run the card module. Not used by the 98550A. |
| 0x2D | 0x15FC / 0x19D6 | Bitmap console init from the card ROM. |
| 0x2C | 0x1610 | No usable font in the card ROM. |
| 0x0C | 0x1618 | Card ROM checksum (8 KB). |
| 0x0D | 0x169A / 0x174A | DIO-II graphics candidate. |
| 0x2E | 0x17C2 / 0x19FE | Alpha-display probe / console line. |
| 0x0E | 0x18E2 step 19990 | Boot ROM checksum. |
| 0x22 | 0x1A72 step 4990 | 8042/HIL self-test result. |
| 0x0F | 0x1BE0 step 1000 | RAM sizing. |
| 0x2F | 0x1C5C step 900 | Alpha/bitmap video RAM test (3xx hardware). |
| 0x24 | 0x49CE step 800 | Built-in HP-IB found. |
| 0x28 | 0x1DE4 step 700 | 98620 DMA probe. |
| 0x10 | 0x2542 step 400 | RAM test. |
| 0x11 | 0x2678 step 398 | Memory error. |
| 0x40-0x5F | 0x1FDA step 200 | DIO-I select code `sc` being probed (0x40 \| sc). |
| 0x84-0xFF | 0x1FDA step 200 | DIO-II select code being probed (LED = sc, 132..255). |
| 0x12 | 0x23D6 step 100 | ROM-extension / boot-device scan. |
| raw | 0x272A step 20 | Blink: ~(fed9 & 0xC0) with bit 4 toggling, 7 × 166 ms. |
| 0x00 | 0x3EEC step 10 | Tests done. The raw latch then gets ~(highest failure code) (0x3EFC). |
| 0x14 / 0x15 / 0x16 / 0x17 / 0x23 | 0x43E2 / 0x43F0 / 0xCAA / 0x7F72 / 0x7168 | Boot-loader and console error paths, e.g. "NOT ENOUGH MEMORY" (0x15). |

`test_failed` (0x4FCC) records the current code as a failure. ($cb,A4) keeps the highest one, and step 10 shows it.

### 1.5 Self-test step tables [V]

The step tables at 0x102E, 0x10BC, 0x1128 and 0x11E8 hold (key.w, routine.l) entries in descending key order, ending with 0.

**Choosing a table** [V for the code, I for which branch applies on a real 380]:

- `step_table_select` (0x822) is indexed by the 2-bit test mode: 0 → 0x10BC, 1 → 0x102E, 2 → 0x1128, 3 → 0x102E.
- The mode comes from EEPROM byte $fedb bits 1:0, or fed3 when fed9 bit 5 is set.
- **With no config EEPROM** (our core) and no upper ROM, $fedb = 0x22, so **mode 2 → table 0x1128**, which is the normal boot.
- Mode 1/3 tables end with step 1 → Configuration Mode (0x10AC).
- The mode 0 table ends with step 1 → `halt`.

The executor (0x1236) merges the selected table with an extension table ($30,A4; the default at 0x11E2 is empty). Equal keys are overridden by the extension.

**Table 0x1128, in order:**

| Key | Routine | Purpose |
|---|---|---|
| 32000 | 0x14B0 | Probe 0x880000 for 0x4EF9. If found, set ($b,A4) bit 6 (suppresses `RESET`). |
| 31000 | 0x14CA | LED 08: 8042 command 0x31, `RESET`, PTM re-init, 50 µs delay. |
| 30990 | 0x5448 | CACR = 0; **0x5F400E \|= 0x60**; on a 68040, ITT0/1 = DTT0/1 = 0, then **DTT0 = 0x00FFC040** and **0x5F4003 = 7**. |
| 28000 | 0x1D42 | Initialise a device at 0x300000xx (protected against bus errors; absent on a 380). |
| 27000 | 0x1518 | LED 09: console search (1.9). |
| 26990 | 0x7A14 | Console variables. |
| 20000 | 0x5240 | Print the copyright lines. |
| 19990 | 0x18E0 | LED 0E: **boot ROM checksum** (1.6). |
| 19980 | 0x1A24 | Print "MC680x0 Processor". The digit at 0xFDD7 becomes 4, 2 or 3. |
| 9000 | 0x1E84 | FPU detection via the `FSAVE` frame size (68020/030 only; skipped on an 040). |
| 9900 | 0x1DC8 | Probe 0x5D0001 == 0x2A (HP98286). |
| 9800 | 0x4B7C | "Configuration EEPROM" line. |
| 7990 | 0x12EE | Extension hook 6/7. |
| 7980 | 0x129E | Extension hook 1. |
| 5000 | 0x1A674 | Console state. |
| 4990 | 0x1A60 | LED 22: 8042 self-test result. Expects status (0x428003) & 0xF0 == 0x70 and data 0x8E within 0.5 s. Fills the RAM vector slots 0xFFFFFEE0-0xFFFFFFF9 with `JSR 0x4F66`, then HIL init. |
| 4980 | 0x8312 | Extension hook 4. |
| 3000 | 0x6FAC | Remote-console banner. |
| 2000 | 0x1BBA | Enable interrupts. |
| 1000 | 0x1BD2 | LED 0F: **RAM sizing** (1.6). |
| 900 | 0x1C5A | LED 2F: 3xx video RAM test. |
| 800 | 0x4996 | LED 24: built-in HP-IB at 0x478003. Bits & 0xC1 must read 0x80. |
| 700 | 0x1DE2 | LED 28: 98620 at 0x500000, second block at 0x508000. |
| 400 | 0x2528 | LED 10: **RAM test** (1.6). |
| 398 | 0x260E | LED 11 on error. Memory report and free-memory setup. |
| 390 | 0x4F98 | Call 0xB3A4 (Pascal-side init). |
| 380 | 0x19E3C | Run registered drivers. |
| 200 | 0x1FA0 | DIO select-code scan (1.9). |
| 100 | 0x23D4 | LED 12: ROM-extension scan from 0x20000 to 0x3FFFFF. |
| 20 | 0x2718 | LED blink, 7 × 166 ms. |
| 10 | 0x3ED8 | LED 00 and the failure summary / prompts. |

The other tables are subsets:

- **0x102E (mode 1/3)** omits the hooks and some probes, and ends with step 1 = 0x10AC (Configuration Mode).
- **0x10BC (mode 0)** uses a quiet scan (200 → 0x1EDC), and ends with step 2 = hook 8 and step 1 = `halt`.

### 1.6 Checksum, RAM sizing and RAM test; fast-boot patch points

**ROM checksum** [V, computed]:

- `checksum_2x16` is at **0x5052**.
  - Input: A0 = start, D4 = length.
  - Loop: `MOVEP.W (0,A0)` and `MOVEP.W (1,A0)`, i.e. the byte pairs at A0/A0+2 and A0+1/A0+3, then A0 += 4.
  - It keeps two 16-bit **end-around-carry** sums: D2 over the bytes at addresses ≡ 0,2 (mod 4), and D3 over the bytes ≡ 1,3.
  - Result: D0 = (D2+1) \| (D3+1), so D0 = 0 means the image is good (both sums 0xFFFF).
- Step 19990 calls it at **0x18F6** with A0 = 0 and D4 = 0x20000, i.e. over the whole 128 KB including the adjust bytes.
- The adjust value is the long at **0x1FFFC** = 0x3558BBFD [I that this is the designated adjust field; the four bytes before it are zero]. The image sums to 0xFFFF/0xFFFF [V].
- A mismatch only prints "BOOTROM … Failed" and records code 0x0E. **It does not halt.**
- The same routine checks extension ROMs (0x904) and card-ROM modules (0x84BE).
- `card_rom_checksum` (0x5086) is the variant used on graphics card ROMs. Over the odd-byte stream it is the same sum, with the low byte of the first word excluded.

**RAM sizing** [V], step 1000 at 0x1BD2:

- Skipped if ($b,A4) bit 4 is set (memory already set up).
- Enables the I-cache (0x53FC: 040 CACR = 0x8000).
- Starts at ($366,A4) & ~3 (0xFFFFFAC0) and walks **downward until a bus error**:
  - **Non-parity** (always on a cold boot): 0x1C3A `subq.l #4,A0 ; move.l A0,(A0) ; nop ; bra`. The resume address is 0x1C42, which does A0 += 4.
  - **Parity** (($a,A4) bit 0, only inherited on a warm restart): `MOVEM.L D0-D7,(A0)` with 0xEEEE1111 in 32-byte steps. Resume at 0x1C30.
- The lowest good address is stored in **0xFFFFFDCE** (0x1C44).
- **The core must bus-error just below the installed RAM**; 8 MB means bus error at 0xFF7FFFFC.
- For 8 MB this is about 2 M loop iterations.

**RAM tests** [V]:

1. **Top 16 KB, before RAM is known good:** 0x5D0 → `ram_pattern_test` 0x610, register-linked (A4 = return).
   - Range A5 = 0xFFFFC000 to A1 = 0xFFFFFFFF.
   - Patterns 0xEEEE1111 / 0x88887777, rotated each pass.
   - Raw LED 0xFC/0xFB on failure.
2. **Step 400** (0x2528), " Testing Memory".
   - Runs only if **($b,A4) bit 1** is set. That bit is D5 bit 1 from **0x46A `moveq #2,D5`**, the cold-boot default.
   - Non-parity: an address-in-address plus complement test upward from $fdce to ($366,A4) (0x25C0-0x25F2).
   - Parity: `ram_pattern_test` over the whole range.
   - Step 398 (0x260E) reports through A3/A4, which are left behind by step 400 (registers leak between steps).
3. `ram_test_range` (0x513E) is used for card-module RAM.

**Sim fast-boot patches.** `tools/bootrom_simpatch.py` applies these and then recomputes the long at 0x1FFFC so step 19990 still passes:

| Addr | Original | Patched | Effect |
|---|---|---|---|
| 0x004FA | `51C8 FFFA` (dbra D0) | `4E71 4E71` | Lamp test without its 7 × 65536-pass delay. Exit condition unchanged (D0 stays −1). |
| 0x0046A | `7A02` (moveq #2,D5) | `7A00` | Cold boot without the RAM test. Steps 400 and 398 take their "no test" branches cleanly. Preferred over patching 0x2528, because of the A3/A4 leak. |
| 0x02718 | `1038` | `4E75` (rts) | Skip the step-20 LED blink (≈1.2 s of PTM time). |
| 0x018F6 | `6100 375A` (bsr checksum) | `7000 4E71` (moveq #0,D0) | Skip the 128 KB checksum loop. Optional: with the adjust long recomputed the checksum passes anyway; this only saves time. |
| 0x01C36 (optional, `--ramsize-base B`) | `4DFA 000A 5988 2088 4E71 60F8 5888` | `207C BBBB BBBB 6006 4E71 4E71 4E71` | RAM sizing writes no loop: $fdce = B. Valid only on the non-parity path, which is always the case on a cold boot. |

Other time sinks that are left in:

- the top-16K pattern test;
- the 64K-touch loop at 0x4E0, which needs a bus error below RAM;
- the 248 + 248 ROM-extension probes, one bus error each;
- 32 DIO-I + 124 DIO-II probes, one bus error each;
- the 8042 self-test wait (up to 0.5 s if the 8042 is silent).

### 1.7 0x5F4000 system registers and CPU / model identification [V]

**The whole ROM touches the 0x5F4000 block in exactly three places, and never reads it to decide anything:**

| Addr | Instruction | Notes |
|---|---|---|
| 0x53E6 | `move.w #$0000,$5F400E` | Called from reset (0x79C), `halt` (0x4D98), 0x4424 and 0x4F30. A6 points at the following `rts`, so a bus error here is harmless. |
| 0x5450 | `ori.w #$0060,$5F400E` | Word read-modify-write, step 30990. **Not protected**: A6 holds the executor's frame pointer, so a bus error jumps into RAM. This is presumably why MAME says the ROM "crashes" without the block. |
| 0x547A | `move.b #$07,$5F4003` | 68040 path only, step 30990, right after DTT0 = 0x00FFC040. Not protected. |

[I] In the HP MMU layout used by NetBSD/hp300 (MMUBASE 0x5F4000, MMUCMD/MMUSTAT at +0xC), 0x60 in the low word at +0xE would be MMU_IEN \| MMU_FPE (external I-cache enable, 68881 enable). The meaning of byte +3 = 7 on the 380 is unknown. The NetBSD kernel reportedly reads the "MMU id" from this block to tell a 380 from a 4xx. The boot ROM does not, so a stub of 16 bytes of plain RAM is enough for the boot ROM. What value the OS needs is still open.

**CPU type** (`cpu_detect`, 0x131C) uses CACR read-back:

- Write CACR bit 31 (040 DE). If it reads back → **68040**: $feda bit 3 = 0, bit 2 = 1.
- Otherwise write bit 9 (030 FD). If it reads back → 68030 (bit 3 = 1, bit 2 = 1), else 68020 (bit 3 = 1, bit 2 = 0).
- **The AP68040 core must return CACR bit 31 on read-back**, or the ROM takes the 68030 paths (`PMOVE` SRP/CRP at 0x548E, CACR = 9, FPU `FSAVE` probe).

**Model checks:**

- "MD11 requires MC68040" / "MD12 requires MC68030" (0x1938) depend on a model string returned by extension hook 2. That only exists with an upper 128K ROM ($feda bit 0, via the pointer at 0x3FFF0).
- No machine-model register is read.
- Other control registers: VBR is always 0 (`vbr_clear`, 0x1E3F4). TC is never written, so the MMU stays off. Caches: I-cache only (CACR 0x8000) around sizing and the RAM test; `CINVA` at 0x540C and 0x5428.

### 1.8 PTM (MC6840 at 0x5F8000) [V]

Init (0x1374):

1. CR2 = 0 (select CR3).
2. **CR3 = 0x84.**
3. CR2 = 0x01 (select CR1).
4. CR1 = 0x01 (all timers held in reset).
5. T2 latch = T3 latch = 0xFFFF.
6. CR1 = 0 (release).

All time-keeping reads **T2:T3 as one 32-bit down-counter**: `MOVEP.L ($9,A0)` reads T2 MSB, T2 LSB, T3 MSB, T3 LSB, twice, to fix carries (0x549C). That needs **T3 clocked at 250 kHz (4 µs/tick) and T2 clocked by O3**, as in MAME. `delay_us` (0x5532) and the timeouts (0x54E2 / 0x5502) are built on it. If the counter does not move, the CPU halts with LED 0x20 (0x13B2).

### 1.9 Console and device search [V]

**Step 27000 (0x1518), console search:**

1. **Internal graphics at 0x560000.**
   - ID byte 0x560001: requires (ID & 0x1F) == 0x19 and bit 6 == 0. The 98550A gives 0x39.
   - Card-ROM bytes 0x42/0x43 (bus 0x85/0x87, `MOVEP`) are a 68k module pointer. When nonzero, the module is loaded and run (0x8434). On the 98550A it is 0.
   - Bitmap console init (`bitmap_console_init` 0x626E, LED 2D):
     - init tables via `grf_card_init_tables` 0x5CAC (format in section 2);
     - FB address via `grf_fb_address` 0x6348;
     - font via `grf_find_font` 0x6392 (font id 1);
     - rows = DHEIGHT / font height, columns = DWIDTH / font width;
     - console JMP slots at ($4E-$6A,A4).
   - The card ROM's first 8 KB is checksummed (0x1636, LED 0C).
2. **DIO-II graphics**, if ($a,A4) bit 1 (always set on a cold boot): 0x1000000 to 0x20000000 in 4 MB steps (sc 132..), same ID test. The card size comes from the byte at +0x101.
3. **3xx alpha display** at 0x510000 (not on a 380).

**Step 200 (0x1FA0), device list:**

- DIO-I sc 0-31 at **0x600000 + sc × 0x10000**, LED 0x40 \| sc. A bus error means the slot is empty (resume 0x229C).
- Reads the ID at +1, & 0x7F. Select code 7 (built-in HP-IB) is handled specially.
- Prints the name from the ID table at 0x5A59, then per-ID tests:

| ID | Card | Action |
|---|---|---|
| 0x01 | 98624 HP-IB | 0x4A16 |
| 0x02 / 0x42 | 98626 / 98644 serial | 0x4B1A |
| 0x05 | 98622 GPIO | 0x7D36 |
| 0x08 / 0x48 | 98625 HS HP-IB | 0x16140 |
| 0x09 | HIL / remote console | |
| 0x15 | 98643 LAN | 0x488C |
| (ID & 0x1F) == 7 | 98265 SCSI | 0x17838, SCSI self-test |
| 0x34 | 98628 | |
| 0x51 | VXI | |
| (ID & 0x1F) == 0x19, bit 6 = 0 | graphics | |

- Multi-select-code cards (0x51, and ID & 0x1F ∈ {0x1A, 0x1C, 0x1D}) skip extra codes.
- Then **DIO-II**: sc 132-255 at 0x1000000 + (sc − 132) × 4 MB, LED = sc, sized by +0x101.

Messages:

- Graphics: "Bit Mapped Video" / "Color Graphics".
- Keyboard: "HP-HIL" / "HP-HIL.Keyboard" / "Console Keyboard at".
- Remote console: "Remote Console at", "After beeps, type L RETURN …".

**8042 commands sent by the boot ROM** [V]:

| Command | Where / meaning |
|---|---|
| 0x31 | Step 31000 |
| 0x5F | 0x4488, 0x702E |
| 0xA3 + 2 data | Tone (0x6F72) |
| 0xB2 | Clear NMI (0x7034) |

Command bytes go to 0x428003 and data to 0x428001. The ROM waits for IBF to clear (status bit 1) and for OBF (status bit 0).

### 1.10 Strings (all user-visible text with addresses) [V]

The main tables are at 0x556C-0x5C13 (prompts and messages), 0x16C60 (SCSI test texts), 0x1A0xx-0x1A50C (self-test menu) and 0x1AA54-0x1D60C (configuration menus). Entries tagged `[card id …]` are the ID → name table at 0x5A59. Non-printing bytes are shown as `\xNN`; in the menus they are record headers or Pascal length bytes.

| Addr | String |
|---|---|
| 0x00A8A | `preferred selection` |
| 0x01980 | `MD11 requires MC68040 Processor` |
| 0x019A0 | `MD12 requires MC68030 Processor` |
| 0x0211C | ` (Console)` |
| 0x02127 | `    turn on` |
| 0x03FD0 | `BOOTROM  Rev. 2.0  29 NOV 90` |
| 0x0452C | `\x07UNKNOWN` |
| 0x04546 | `\x05EPROM` |
| 0x0556C | `RAM FAILED ABOVE FFFFC000` |
| 0x05586 | `RAM GONE ABOVE FFFFC000` |
| 0x0559E | ` Testing Memory` |
| 0x055AE | ` Loading Memory` |
| 0x055BE | ` Booting System` |
| 0x055CE | ` Searching for Selected System` |
| 0x055ED | ` System Search Mode` |
| 0x05601 | ` System Search Mode, will store selection` |
| 0x0562B | ` Configuration Mode` |
| 0x0563F | ` Select System, type RETURN` |
| 0x0565B | ` Select System, type ENTER` |
| 0x05676 | ` is System Selected      ` |
| 0x05690 | ` Search Paused (ENTER To Continue)` |
| 0x056B3 | ` Search Paused (RETURN To Continue)` |
| 0x056D7 | ` Self-Test Mode` |
| 0x056E7 | ` RESET To Restart` |
| 0x056F9 | ` RESET To Restart, SPACE clears input` |
| 0x0571F | ` Continue at Own Risk (ENTER To Continue)` |
| 0x05749 | ` Continue at Own Risk (RETURN To Continue)` |
| 0x05774 | ` Waiting 1 Minute (ENTER to Abort Wait)` |
| 0x0579C | ` Waiting 1 Minute (RETURN to Abort Wait)` |
| 0x057C5 | ` UNEXPECTED USE OF ` |
| 0x057DA | ` NOT ENOUGH MEMORY` |
| 0x057ED | ` SYSTEM WOULD LOAD TOO HIGH` |
| 0x05809 | ` SYSTEM NOT FOUND` |
| 0x0581B | `Copyright 1990,` |
| 0x0582B | `Hewlett-Packard Company.` |
| 0x05844 | `All Rights Reserved.` |
| 0x0585B | `MC68000 Processor` |
| 0x0586E | `Alpha Video` |
| 0x0587A | `Bit Mapped Video` |
| 0x0588B | `HP-HIL` |
| 0x05892 | `HP-HIL.Keyboard` |
| 0x058A2 | `Console Keyboard at   ` |
| 0x058B9 | `Color Graphics` |
| 0x058C8 | `Graphics` |
| 0x058D1 | `HP-IB` |
| 0x058D7 | `HP98620` |
| 0x058E4 | `HP98635` |
| 0x058EC | `HP98248` |
| 0x058F4 | `FP Coprocessor` |
| 0x05903 | `MC68881 Coprocessor` |
| 0x05917 | `MC68882 Coprocessor` |
| 0x0592B | `HP98286 Coprocessor` |
| 0x0593F | ` Bytes` |
| 0x05946 | `Memory Failed at ` |
| 0x05958 | `Memory Gone at ` |
| 0x05968 | `Data Parity Error at ` |
| 0x0597E | `Parity Bit Error at ` |
| 0x05993 | ` Ignored` |
| 0x059A1 | ` Failed` |
| 0x059A9 | ` Passed` |
| 0x059B1 | `SYSTEM_` |
| 0x059C3 | `Remote Console at ` |
| 0x059D6 | `After beeps, type L RETURN to use the local monitor as console. ` |
| 0x05A17 | ` Type R RETURN for internal RS-232 console ` |
| 0x05A43 | `Configuration EEPROM ` |
| 0x05A59 | [card id 0x01] `HP98624 (HP-IB)` |
| 0x05A6A | [card id 0x02] `HP98626 (RS-232)` |
| 0x05A7C | [card id 0x42] `HP98644 (RS-232)` |
| 0x05A8E | [card id 0x03] `HP98622 (GPIO)` |
| 0x05A9E | [card id 0x04] `HP98623 (BCD)` |
| 0x05AAD | [card id 0x05] `HP98642 (RS-232 MUX)` |
| 0x05AC3 | [card id 0x06] `HP PARALLEL` |
| 0x05AD0 | [card id 0x07] `HP98265 (SCSI S 32)` |
| 0x05AE5 | [card id 0x27] `HP98265 (SCSI S 16)` |
| 0x05AFA | [card id 0x47] `HP98265 (SCSI D 32)` |
| 0x05B0F | [card id 0x67] `HP98265 (SCSI D 16)` |
| 0x05B24 | [card id 0x08] `HP98625 (HS HP-IB)` |
| 0x05B38 | [card id 0x48] `HP-IB (HS 32)` |
| 0x05B47 | [card id 0x09] `HP-HIL.Keyboard` |
| 0x05B58 | [card id 0x0C] `HP98647` |
| 0x05B61 | [card id 0x11] `HP98646 (VME)` |
| 0x05B70 | [card id 0x31] `HP98577 (VME)` |
| 0x05B7F | [card id 0x51] `HP E1480A (VXI)` |
| 0x05B90 | [card id 0x12] `HP98640` |
| 0x05B99 | [card id 0x15] `HP98643 (LAN)` |
| 0x05BA8 | [card id 0x16] `HP98695` |
| 0x05BB1 | [card id 0x19] `Bit Mapped Video` |
| 0x05BC3 | [card id 0x39] `Bit Mapped Video` |
| 0x05BD5 | [card id 0x1B] `HP98253` |
| 0x05BDE | [card id 0x1C] `HP98627` |
| 0x05BE7 | [card id 0x1D] `HP98633` |
| 0x05BF0 | [card id 0x1E] `HP98259 (BUB)` |
| 0x05C03 | `HP98628 (RS-232)` |
| 0x09E38 | `SYSTEMS         ` |
| 0x0C400 | `HPS300              ` |
| 0x0E2CA | `Server AbortedNu`` |
| 0x10256 | `\x05 REMV` |
| 0x1025C | `\x05 FIXD` |
| 0x10262 | `\x05 TAPE` |
| 0x10268 | `\x13CS80 unknown device` |
| 0x1051A | `HP98259.` |
| 0x11D00 | `\x05 REMV` |
| 0x11D06 | `\x07unknown` |
| 0x11D0E | `\x0dunknown, ec= ` |
| 0x16C60 | `    interface configuration error           fuse burned out                         register test fa...` |
| 0x16F30 | `: register tests ` |
| 0x16F42 | `: loop back tests` |
| 0x16F54 | `: cable tests    ` |
| 0x19FA6 | `Type Y or N ENTER ? ` |
| 0x1A122 | `Type 50 or 60 ENTER ? ` |
| 0x1A25A | `Type [key] ENTER ? ` |
| 0x1A274 | `Type [key] RETURN ? ` |
| 0x1A28F | `\x03    Self Test Controls` |
| 0x1A2AD | `\x03Keys Test Option   Selected` |
| 0x1A2EC | `  1  Continuous          ` |
| 0x1A308 | `f\x0epY\x088` |
| 0x1AA56 | `Configure Mode Failed` |
| 0x1AA6C | `EEPROM has bad information` |
| 0x1AA87 | `Too much data to save` |
| 0x1AA9D | `EEPROM Load section missing` |
| 0x1AAB9 | `EEPROM Defaults section missing` |
| 0x1AAD9 | `EEPROM Misc. Constants missing` |
| 0x1AAF8 | `Too many configuration saves` |
| 0x1AB15 | `Can not save configuration` |
| 0x1AB30 | `EEPROM can not save information` |
| 0x1B890 | `Must cycle SPU power to complete default setup` |
| 0x1BC48 | `Type   ..    except used` |
| 0x1BC61 | `  used select codes are:` |
| 0x1BC7A | ` RETURN ? ` |
| 0x1BC85 | ` ENTER ? ` |
| 0x1C1CA | `Type   ..   ` |
| 0x1CBBC | `  X  eXit menu` |
| 0x1CBCB | `keys Feature         Value` |
| 0x1CCB4 | `MCS FOUND` |
| 0x1D11E | `  Configurable Interfaces` |
| 0x1D138 | `keys Interface  Select Code` |
| 0x1D170 | `  N  store New values` |
| 0x1D186 | `  D  store Default values` |
| 0x1D1A0 | `    (then cycle SPU power)` |
| 0x1D1BB | `  A  Abort without changes` |
| 0x1D1D6 | `  R  use Remote terminal` |
| 0x1D1EF | `  L  use Local display` |
| 0x1D208 | `Type [key]` |
| 0x1D213 | `Type T or P ` |
| 0x1D220 | `   Temporary or Permanent` |
| 0x1D23A | `   Configuration Control` |
| 0x1D253 | `keys Control Class` |
| 0x1D267 | `\x01\xdb\xdc  *  I/O Configuration` |
| 0x1D283 | `\x01\xd4\xa8  *  Auto System Selection` |
| 0x1D2A3 | `\x01\xd8\xe2  *  Boot Mode Selection` |
| 0x1D2BF | `     Boot Mode Selection` |
| 0x1D2D8 | `keys Mode            Status` |
| 0x1D2F5 | `\x01\xd6\xa2  C  Clear Temporary` |
| 0x1D30F | `\x01\xd9\xb8  E  Execute` |
| 0x1D321 | `\x01\xd5\xa8  E  Execute` |
| 0x1D331 | `   Auto System Selection   ` |
| 0x1D34D | `keys Option          status` |
| 0x1D36B | `\x01\xd3\xd6  *  Scan for System       ` |
| 0x1D38F | `\x01\xd4*  *  Selected System       ` |
| 0x1D3B3 | `\x01\xd4d  *  Store Selected Sys.   ` |
| 0x1D5E3 | `\x01\xd6\x0c Domain Compatible` |
| 0x1D5FA | ` HP-UX Compatible` |
| 0x1D60C | ` undefined` |

---

## 2. HP 98550A card ROM: summary

There is **no 68k code** in this ROM [V]:

- The module pointer at file bytes 0x42/0x43 (bus 0x85) is 0.
- The image contains no RTS/LINK/MOVEM patterns.
- Everything non-zero is accounted for by the header, two init tables, the font directory, two fonts and two checksum words.

The boot ROM interprets the tables itself.

### 2.1 Header

Offsets are file bytes; bus = 0x560000 + 2n + 1.

| File | Bus | Value | Field |
|---|---|---|---|
| 0x00 | 0x01 | 0x39 | DIO ID: (id & 0x1F) == 0x19 = bitmap display |
| 0x02-03 | 0x05/07 | 0x0800 | FB width 2048 |
| 0x04-05 | 0x09/0B | 0x0400 | FB height 1024 |
| 0x06-07 | 0x0D/0F | 0x0500 | display width 1280 |
| 0x08-09 | 0x11/13 | 0x0400 | display height 1024 |
| 0x0A | 0x15 | 0x06 | secondary ID (the boot ROM special-cases 0x0B/0x0D) |
| 0x0C | 0x19 | 0x01 | byte-per-pixel flag → ($12b,A4) |
| 0x11-12 | 0x23 | 0x0103 | **init table 0** → file 0x81 |
| 0x13-18 | 0x27/2B/2F | 0 | alternative table-0 pointers (unused) |
| 0x19-1A | 0x33 | 0x6001 | nonzero → run table 1 |
| 0x1B-1C | 0x37 | 0x4000 | [I] Catseye register-block offset |
| 0x1D-1E | 0x3B | 0x7101 | **font directory** → file 0x3880 (NetBSD `FONTROM`) |
| 0x1F-20 | 0x3F | 0x03DD | **init table 1** → file 0x1EE |
| 0x21-26 | 0x43/47/4B | 0 | table-1 variants |
| 0x2B-2C | 0x57 | 0 | variant selector pointer (none) |
| 0x2E-2F | 0x5D | 0x00FF | pointer to the FB-address byte → file 0x7F = **0x20** → FB at **0x200000** |
| 0x40 | 0x81 | 0x08 | unknown |
| 0x42-43 | 0x85 | 0 | 68k module pointer (none) |
| 0x80 | 0x101 | 0x03 | DIO-II card size field: ((3 >> 2) + 1) × 4 MB |

### 2.2 Init tables

Interpreter: boot ROM 0x5CAC.

**Record format:** `flags.b count.b offset.w` followed by data.

| Flag bit | Meaning |
|---|---|
| bit 7 | last record |
| bit 2 | long fill: count.l, offset.l, value.l |
| bit 0 | wait until bit `b` of the word at `offset` equals the polarity (polarity.b, bit.b), 3 s timeout |
| bit 6 | alternating two-word fill |
| none of these | write (count + 1) words to consecutive word registers |

Offsets are relative to 0x560000.

**Table 0, register setup, in programming order:**

1. **Nereid** word registers 0x21, 0x23, 0x25, 0x27, 0x28-0x2D, 0x2F, 0x42 ← 0x50, 0x6A, 0x52, 0x5C, 0x6B, 4, 0x22, 0x22, 4, 7, 0, 0xFF. Presumably video timing; MAME does not model these.
2. Nereid 0x2E (BLANK_ALL) ← 0xFF.
3. **Catseye** STATUS (0x564800) ← 0.
4. +0x518 ← 0x0100, 0x0200, 0x0400, 0x0800, 0x1000, 0x2000 (one write per bit; register not named in MAME).
5. VB1, TRRCTL1, ACNTL1, PLANEMODE1 ← 0.
6. FBEN1/FBEN2 ← 0xFF00; TCREN1/2 ← 0x0100; TCWEN1/2 ← 0xFF00; PRR1/2 ← 0x0300; WRR1/2, TRR1/2, COLOR1/2 ← 0.
7. RUG_REV/misc (0x564204) ← 0x2C; RUG_SC ← 0x90.
8. WM source/dest X/Y ← 0; WMWIDTH ← 0x500; WMHEIGHT_T (0x56430A, which triggers the operation) ← 0x400. This is a full-screen window move / clear.
9. **Wait** for STATUS bit 0 clear.
10. FBEN2 ← 0.
11. Nereid 0x50 ← 0, OVERLAY_CTL ← 0, PLANE_MASK ← 0xFF, OVERLAY_INDEX ← 0 (last).

**Table 1, colormap:**

1. PLANE_MASK ← 1, OVERLAY_INDEX ← 0, then wait for Nereid BUSY bit 2 clear.
2. Entry 0 = (0, 0, 0): INDEX0, RED, GREEN, BLUE, WRITE_STROBE.
3. Entry 1 = (0xFF, 0xFF, 0xFF).
4. Entry 0xFF = (0xFF, 0xFF, 0xFF).
5. Final wait (last).

Bank-2 registers appear at byte offset 0x700 (FBEN2 = 0x564700), matching MAME's word index 0x380.

### 2.3 Fonts [V]

**Directory** at file 0x3880 (bus 0x7101): count = 2, then (id, bus offset):

| Font id | Bus offset | File offset |
|---|---|---|
| 1 | 0x7201 | 0x3900 |
| 2 | 0x1701 | 0x0B80 |

The boot ROM uses font id 1.

**Font header** (5 file bytes): height, width, ?, first char, last char. The glyphs start at header + 5, which is bus + 0xA and matches NetBSD's `FONTDATA`. Each glyph row is one 16-bit big-endian word with the leftmost pixel in the MSB.

| Font | Size | Characters | Data | Notes |
|---|---|---|---|---|
| 1 | 10 × 20 | 0x00-0xFF | 0x3905-0x6104 | full Roman-8 |
| 2 | 10 × 20 | 0x80-0xFF | 0x0B85-0x1F84 | Katakana-style alternate upper half (judged from the glyph shapes) |

### 2.4 Checksums [V]

Both blocks are 16-bit end-around-carry sums of big-endian file words and equal 0xFFFF:

| Block | Adjust word |
|---|---|
| 0x0000-0x1FFF | 0x1FFE = 0x0CD6 |
| 0x2000-0x7FFF | 0x7FFE = 0xE77E |

The boot ROM checks the first block (0x1636: 0x4000 bus bytes). Who checks the second block is not known.

---

## 3. 8042 HIL controller firmware (1820-4784): summary

About 1.9 KB of the 2 KB is code, reached from the three vectors.

| Vector | Address |
|---|---|
| reset | 0x000 |
| IBF interrupt (host wrote DBB) | 0x003 |
| timer interrupt | 0x007 |

The data areas are:

- page-3 `MOVP3` translation tables at 0x300-0x38F;
- a 6-byte bit-mask table at 0x600-0x605 (OR masks 40 10 02, AND masks BF EF FD);
- filler at 0x0FF, 0x2FF and 0x4FD-0x4FF.

### 3.1 Ports [V for the firmware's use; the pin wiring is from MAME]

| Pin | Firmware usage |
|---|---|
| P1 | Data bus to the control latch, MLC, SN76494 and RTC. Set to 0xFF before reads. |
| P2.0 | MLC chip select (low active, 0x2BB/0x2D7) |
| P2.1 | MLC WE (0x2D9) / RTC address-write pulse (0x5EC) |
| P2.2 | MLC OE (0x2BD) / RTC write pulse (0x5C4) |
| P2.3 | Latch enable: low then high captures P1 into the latch (0x2B5, 0x2D2, 0x5E1, 0x5F4) |
| P2.4 | `EN FLAGS` at 0x01D makes P2.4 the **OBF interrupt output** → host **IRQ1**: every `OUT DBB` raises it. |
| P2.5 | Sampled at reset (0x000/0x022): RAM[0x7E] = 0x1B if high, 0x3B if low. Afterwards it is /IBF. |
| P2.6 | Low = **host NMI** (IRQ 7). Asserted at 0x258 and 0x6F1 (keyboard-reset path); released at 0x173 (command group 0x9x/0xBx, e.g. 0xB2 = NetBSD `HIL_CNMT`). |
| P2.7 | SN76494 write strobe (0x2F4) |
| T0 | MLC interrupt, polled at 0x57B and 0x72A |
| Timer | Tick → RAM[0x27] (0x007). Used for key repeat and tone duration. |

**Latch values written through P1:**

| Latch | Meaning |
|---|---|
| (reg << 6) \| 0x20 | MLC register `reg` |
| 0x10 | RTC selected (CS2) |
| 0x20 | idle / RTC deselected |

### 3.2 Host interface [V]

**Init:**

- STS = 0x70.
- Warm or cold start is decided by RAM[0x6F] == 0xAA and RAM[0x7F] == 0x55 (0x19C). A cold start clears RAM 0x01-0x7D.
- The **ready/self-test byte 0x8E** is sent with status 0x7x (0x06F). This is exactly what boot ROM step 4990 checks.

**IBF handler (0x074):**

- F1 = 1 means the byte is a command (written to 0x42xxx3). The command goes to the decoder at 0x100.
- Otherwise the byte is data, stored at RAM[R5] with R5 auto-incremented. R5 is set by the previous command.
  - R5 bit 7 → RAM[0x70 + n].
  - Commands 0x88-0x8F → add to RAM.
  - Writing pointer 0x24 starts a tone (0x390).

**Command decoder (0x100):**

| Command | Handler | Action (NetBSD name where it matches, [I]) |
|---|---|---|
| 0x00-0x1F | 0x107 | R6 = cmd, deferred to the main loop (0x205), e.g. read-type commands. 0 = no-op. |
| 0x20-0x3F | 0x148 | Copy RAM[cmd−5 .. cmd] → RAM[0x12..0x17]. The boot ROM sends **0x31**. |
| 0x40-0x7F | 0x156 | RAM[4] = (RAM[4] & 0xE0) \| (cmd & 0x1F). 0x5C / 0x5D = `HIL_INTON` / `HIL_INTOFF`. |
| 0x80-0xBF | 0x114 | R5 = cmd & 0x3F = data pointer. 0xA0 `SETARD`, 0xA2 `SETARR`, 0xA3 `SETTONE` (2 bytes → RAM[0x23..0x24], tone starts). Bit 4 set (0x9x/0xBx) → 0x16D: mask / NMI handling. Bit 3 (0x88-0x8F) → 0x161. |
| 0xC1 | 0x124 | R6 = 0 |
| 0xC2 | 0x5BF | **RTC write** (`BBC_WRITE_REG`): RAM[0x70] = value << 4 \| register |
| 0xC3 | 0x5CC | **RTC read** (`BBC_READ_REG`): the result goes to RAM[0x70] and is sent through the deferred R6 = 0x70 |
| 0xC4 | 0x3CD | Write RAM[0x70..0x72] to the SN76494, then RAM[0x74 + channel] = RAM[0x73] (duration) |
| 0xC5 | 0x28A | **MLC trigger** (`HIL_TRIGGER`): wait for MLC R1 bit 4 clear, W1 = RAM[0x70], W0 = RAM[0x71] (sends a frame), RAM[0x6A] = RAM[0x72] |
| 0xC0, 0xC6-0xDF | — | ignored |
| 0xE0-0xEF | 0x13A | Next data byte → RAM[0x70 + n] (`BBC_SET_REG` = 0xE0) |
| 0xF0-0xFF | 0x141 | Deferred: send RAM[0x70 + n] back to the host |

**Output to the host:** `OUT DBB` at 0x26D / 0x531, with the status high nibble set by `MOV STS` to tag the data type: 0x70 at init, 0x40, 0x10, (R5 << 2) & 0x30, or a queued status byte. Each output raises IRQ1 through P2.4/OBF.

HIL data is queued as (status, data) byte pairs in RAM 0x40-0x67. `queue_put` (0x500) writes them at pointer RAM[0x69], with status 0x50 or 0x60 from 0x68A/0x68E. `queue_send` (0x527) sends them from pointer RAM[0x68] whenever OBF is clear.

### 3.3 MLC, RTC and beeper routines [V]

**MLC reads** (latch, CS low, OE low, `IN A,P1`):

| Register | Routine |
|---|---|
| R0 | 0x2A6 |
| R1 | 0x2AA |
| R2 | 0x2AE |
| R3 | 0x2B2 |

**MLC writes** (latch, data on P1, CS low, WE low):

| Register | Routine |
|---|---|
| W0 (send frame) | 0x2C2 |
| W1 | 0x2C8 |
| W2 | 0x2CE |

The link poll / loop state machine is at 0x603-0x6F3 and 0x704-0x7FE (reconfigure, loop states, device polling).

**RTC (MSM58321):**

| Routine | Address | What it does |
|---|---|---|
| `rtc_select` | 0x5DF | Latch 0x10 (CS2), P1 = address (low nibble of RAM[0x70]), P2.1 pulse |
| write | 0x5BF | P1 = data nibble (high nibble of RAM[0x70]), P2.2 pulse |
| read | 0x5CC | Latch with P1 = 0xFF, then two `IN A,P1` reads, & 0x0F |
| deselect | 0x5F1 | Latch 0x20 |

**Beeper (SN76494):**

- Write routine at 0x2F3: P1 = byte, P2.7 low/high.
- At init all four channels are silenced: 0x9F, 0xBF, 0xFF, 0xDF (0x0E9).
- Tone from `SETTONE` at 0x390 (frequency computation, writes 0xC0 \| n and an attenuation byte). Tone timers at 0x3E2.

---

## 4. Open questions

1. **0x5F4000.**
   - What the 380 hardware returns at +0xC/+0xE.
   - The meaning of byte +3 = 7.
   - What NetBSD/HP-UX read there to identify a 380. The boot ROM needs only that the block exists and does not bus-error. Check NetBSD `locore.s` (`mmuid`) before choosing values.
2. **Which test mode a real 380 uses.** The default without an EEPROM (mode 2, table 0x1128) is inferred from code. A real 380 has a config EEPROM (controller at 0x400000, data at 0x408001 + 2n). With the EEPROM image (still wanted, see `docs/ROMS.md`) the mode would come from item 3.
3. **8042 command 0x31** at step 31000. The firmware copies RAM 0x2C-0x31 to 0x12-0x17; its higher-level meaning (restore defaults?) is unconfirmed.
4. **Unidentified 380-family hardware** that the ROM probes but MAME does not map:

   | Address | What it is |
   |---|---|
   | 0x880000 | step 32000; 0x4EF9 = special ROM/hardware |
   | 0x300000xx | step 28000 |
   | 0x5B0000 | RAM-test write |
   | 0x508000 | second DMA block |
   | 0x41C0C0 | FRODO, 4xx only |

   All are protected against bus errors, so leaving them unmapped (BERR) is safe.
5. **Nereid word registers 0x21-0x2F and 0x42** written by the 98550A init table, presumably CRT timing, and Catseye **+0x518**. Neither is modelled by MAME. The core can accept and ignore them, or use them for timing.
6. **The second 98550A checksum block** (0x2000-0x7FFF): which code checks it is unknown.
7. **The post-test boot path** from 0x92A on (system search, LIF/SCSI/HP-IB boot loaders, Configuration Mode menus) is disassembled but only lightly annotated.
