# The previous HP9000/300 MiSTer core (what we're replacing)

Repo: `../hp300_MiSTer`, master `b7d5f3c`.
- Initial commit by Sven Schnelle, Dec 2020.
- Release `.rbf` and `.qpf` added by xolod79, Aug 2021.
- Quartus 17.1, VHDL.

Kept here as a reference only. Nothing from it has been copied.

## Summary

| Area | Implementation | Problems |
|---|---|---|
| CPU | wf68K30L (W. Foerster, rev 2K18A), 68030 ISA, **no MMU, cache or coprocessor**; async 32-bit AS/DSACK bus | FC=7 cycles always get AVEC; there is no F-line or BERR for coprocessor cycles |
| Clocks | PLL 64 MHz (pixel) + 200 MHz, divided in the fabric to 100/50 MHz; CPU at 50 MHz | `hp300.sdc` is missing; `ps2_key`/`status` cross clock domains with no synchronizer |
| Boot ROM | `bootrom_d.vhd`: **"NuBOOTROM Rev. D"** (1989, 68030-era), 128 KB baked in. Reset SSP=0x100, PC=0x40C | Rev 2.0 is needed for a 68040. The `_sim` variant NOPs the checksum and RAM test (useful trick) |
| RAM | 2 MB @ 0xFFE00000, 16-bit SDRAM @ 50 MHz, BL2, ~9 clk/access | small and slow |
| Video | Topcat 98544, 1024x768 **1 bpp**, VRAM 1M x 1 in BRAM, 64 MHz pixel clock, window mover + 16 rules + cursor | CPU VRAM readback returns write data (bug); no VBLANK status; no IRQ |
| Video ROM | `videorom.vhd`, 8 KB, odd bytes at 0x560001, ID 0x39 | |
| HIL | `hif.vhd`: fake 8042 with a few commands (0x11, 0x12, 0xF9, 0xFA, 0xFE); PS/2 → HP keycode table | no key-up codes, no mouse, no RTC |
| PTM 6840 | `ptm6840.vhd` | IRQ hard-wired 0; loads only the low byte of the latch; status reads 0 |
| IPL | HIL = 1, PTM = 6 | level 1 masks level 6 (if/elsif order) |
| I/O | HP-IB at 0x470000 is a dummy ack; 0x5F4000 is a dummy ack | no SCSI, DMA, serial, LAN or RTC; DIO space bus-errors |
| hps_io | CONF_STR has only reset | `ioctl_download` taken from `status[1]` instead of hps_io, so BASIC never downloads |

## Address decode used (`rtl/hp300.vhd:421-549`)

0x000000 ROM · 0x100000 "BASIC ROM" (SDRAM) · 0x200000 Topcat FB · 0x420000 HIL · 0x470000 HP-IB stub · 0x560000 video ROM · 0x564000 Topcat regs · 0x5F4000 stub · 0x5F8000 PTM · 0xFFE00000 RAM · everything else BERR.

## Worth remembering

- The DIO byte-lane convention it used for 8-bit devices (data on D23:16 with a 16-bit DSACK) works with the HP ROMs.
- The boot ROM sim-patch offsets for Rev D (checksum 0x1438/0x1444, RAM test 0x1DE8) **won't apply to Rev 2.0**. We need to find the equivalents.
- The Topcat window-mover / replacement-rule code (`topcat.vhd:252-328`) is a readable reference for the Catseye WRR path.
