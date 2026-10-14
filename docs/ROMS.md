# ROM images

All three are copyrighted HP firmware. They are **never committed**: `.gitignore` excludes `scratch/`, `*.rom` and `/roms/`.

- **Dev machine:** keep them in `scratch/roms/`, which travels in `scratch.zip`.
- **MiSTer:** they will be loaded from `games/HP9K385/` (loader TBD in Phase 1).

Source: the MAME sets `hp9k380.zip`, `dio98550.zip` and `human_interface.zip` (dated 2021-04-14), copied from `/Volumes/Temp/hp9k380`. All SHA1s were verified against the MAME source on 2026-10-14.

| Role | MAME set | File | Size | CRC32 | SHA1 |
|---|---|---|---|---|---|
| Boot ROM **Rev 2.0** ("NuBOOTROM Rev. 2.0 29 NOV 90", 27C210) | `hp9k380` | `1818-5062_98754_9000-380_27c210.bin` | 128 KB | 500a0797 | 4c0a3929e45202a2689e353657e5c4b58ff9a1fd |
| 98550A card ROM (DIO ID + fonts) | `dio98550` | `98550a.bin` | 32 KB | 9d639233 | d6b23a34850f24525ca5fb36de3deb91196d2dc5 |
| 8042 HIL controller firmware | `human_interface` | `1820-4784.bin` | 2 KB | e929044a | 90849a10bdb8c6e38e73ce027c9c0ad8b3956b1b |

The MAME references were added in 2014-12-31 (`b2288ca1b09`, R. Belmont / Al Kossow skeleton drivers) and 2018-11-18 (`f6efe2921f2`, 98550). The CRCs have not changed since.

## Byte order

- **Boot ROM.** The MAME file is stored **little-endian words** (`ROM_LOAD16_WORD_SWAP`).
  - Swap each byte pair to get the big-endian CPU view. `scratch/roms/hp9k380/bootrom_be.bin` is that swapped copy.
  - After the swap, the reset vectors are **SSP = 0x00000100** and **PC = 0x00000418**.
  - The ROM contains the string "requires MC68040 Processor".
- **98550A ROM.** Stored as a byte stream.
  - The card presents byte *n* at address `0x560000 + 2n + 1` (odd bytes; even bytes read 0xFF).
  - Byte 0 is 0x39, the DIO internal-graphics ID.
- **8042 firmware.** A plain MCS-48 program image (2 KB).

## Still wanted

- **Config EEPROM** (X2816, 2 KB). The site says the image is on Bitsavers.
- The 98556A daughterboard is not needed; STATUS reports "no daughterboard".
