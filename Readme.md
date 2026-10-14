# HP 9000 Model 385 core for MiSTer

**Work in progress.**

In simulation, Boot ROM 2.0 runs all of its self-tests and draws its console on the Catseye model. It detects the HIL keyboard and accepts key presses. No hardware build has been tested yet, and there is no storage yet, so nothing boots an OS.

This core targets the fastest pure HP 9000 Series 300 machine, the Model 385:

- **CPU:** 33 MHz MC68040 with MMU, FPU and caches. It uses the AP68040 core by Adam Polkosnik, vendored from [MacQuadra800_MiSTer](https://github.com/MiSTer-devel/MacQuadra800_MiSTer).
- **Graphics:** HP 98550A "Catseye", 1280×1024 at 8 bits per pixel.
- **Built-in I/O:** HP-HIL keyboard and mouse, MC6840 timer, 98620C DMA, SCSI (98265A), RS-232, and later LAN.
- **Target software:** Boot ROM 2.0, HP BASIC/WS 6.4, Pascal 3.25, NetBSD/hp300 and HP-UX 9.10.

## ROM files

Put these in `games/HP9K385/` on the SD card. They are loaded at start-up.

| File | Contents | Source |
|---|---|---|
| `boot0.rom` | Boot ROM Rev 2.0, `1818-5062_98754_9000-380_27c210.bin` (128 KB), in MAME's word-swapped order | MAME set `hp9k380` |
| `boot1.rom` | HP 98550A card ROM `98550a.bin` (32 KB) | MAME set `dio98550` |
| `boot2.rom` | 8042 HIL controller firmware `1820-4784.bin` (2 KB) | MAME set `human_interface` |

Checksums are in [docs/ROMS.md](docs/ROMS.md).

## Simulation

```
scripts/cpu_regression.sh               # AP68040 self-test suite
make -C verilator run-fast CYCLES=45000000
```

See [docs/BOOT_SIM.md](docs/BOOT_SIM.md) for the harness options, the MAME comparison tools, and what the boot does today.

## Documentation

- [docs/PLAN_385.md](docs/PLAN_385.md): architecture, components, phases and decisions log.
- [docs/BOOT_SIM.md](docs/BOOT_SIM.md): boot ROM behaviour in simulation, the MAME comparison, and the remaining gaps.
- [docs/disasm/README.md](docs/disasm/README.md): analysis of the boot ROM, the 98550A ROM and the 8042 firmware. The annotated listings are generated locally.
- [docs/ROMS.md](docs/ROMS.md): the firmware the core needs. ROMs are **not** included; the user supplies them.
- [docs/reference/](docs/reference/): MAME-derived register spec, CPU integration notes, notes on the previous hp300 core.
- [docs/SITE_NOTES.md](docs/SITE_NOTES.md): notes from hp-series300.net.

## Layout

- `sys/`: MiSTer framework from Template_MiSTer. Do not edit.
- `rtl/ap68040/`: the AP68040 CPU, vendored unmodified (GPL-2.0-or-later, see its `LICENSE` and `UPSTREAM.md`).
- `rtl/wombat/`: the CPU wrapper, store buffer and bus splitter from MacQuadra800_MiSTer, parameterized for the HP 300 memory map.
- `rtl/mem/`: the SDRAM controller and 32-bit beat bridge from MacQuadra800_MiSTer.
- `rtl/hp385_top.sv`: the machine, independent of the MiSTer shell (`HP9K385.sv`).
- `rtl/`: device models: `ptm6840`, `catseye` and `nereid` (98550A), `upi41` and `hil_card` (8042 and HIL), `hpib`, `ps2_hil_keymap`, `vram_ddr3`.
- `verilator/`: headless full-system simulation. `tb/` holds the unit benches. `scripts/` holds the regression and MAME tooling.
- `scratch/`: local working files, git-ignored. They move between machines as `scratch.zip`.

## Credits

- The AP68040 CPU is by Adam Polkosnik, with performance work by Alan Steremberg.
- The `wombat_*` CPU integration comes from the MacQuadra800_MiSTer core.
- The original HP9000/300 MiSTer core is by Sven Schnelle (`hp300_MiSTer`), used as a reference.
- The MAME HP 9000/300 drivers (R. Belmont, Al Kossow, Sven Schnelle and others) are the register-level reference.
- Hardware notes come from [hp-series300.net](https://hp-series300.net/).
- The MiSTer framework is by Sorgelig and contributors.

## License

GPL-2.0 (see `LICENSE`). The vendored components keep their own license headers.
