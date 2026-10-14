# HP 9000 Model 385 core for MiSTer

**Work in progress. Nothing boots yet.**

This core targets the fastest pure HP 9000 Series 300 machine, the Model 385:

- **CPU:** 33 MHz MC68040 with MMU, FPU and caches. It uses the AP68040 core by Adam Polkosnik, vendored from [MacQuadra800_MiSTer](https://github.com/MiSTer-devel/MacQuadra800_MiSTer).
- **Graphics:** HP 98550A "Catseye", 1280×1024 at 8 bits per pixel.
- **Built-in I/O:** HP-HIL keyboard and mouse, MC6840 timer, 98620C DMA, SCSI (98265A), RS-232, and later LAN.
- **Target software:** Boot ROM 2.0, HP BASIC/WS 6.4, Pascal 3.25, NetBSD/hp300 and HP-UX 9.10.

## Documentation

- [docs/PLAN_385.md](docs/PLAN_385.md): architecture, components, phases and decisions log.
- [docs/RESUME-20261014-phase0.md](docs/RESUME-20261014-phase0.md): next-step kickoff.
- [docs/ROMS.md](docs/ROMS.md): the firmware the core needs. ROMs are **not** included; the user supplies them.
- [docs/reference/](docs/reference/): MAME-derived register spec, CPU integration notes, notes on the previous hp300 core.
- [docs/SITE_NOTES.md](docs/SITE_NOTES.md): notes from hp-series300.net.

## Layout

- `sys/`: MiSTer framework from Template_MiSTer. Do not edit.
- `rtl/ap68040/`: the AP68040 CPU, vendored unmodified (GPL-2.0-or-later, see its `LICENSE` and `UPSTREAM.md`).
- `rtl/wombat/`: the CPU wrapper, store buffer and bus splitter from MacQuadra800_MiSTer.
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
