# Resume prompt: Phase 0 (scaffolding and boot ROM in simulation)

Paste everything below the line into a fresh Claude Code session started in the repo root (`HP9K385/`).

---

We're building **HP9K385**, a MiSTer FPGA core for an HP 9000 Model 385:
- 33 MHz MC68040, using the AP68040 core vendored from MacQuadra800_MiSTer.
- HP 98550A "Catseye" 1280×1024×8 graphics.
- The built-in I/O of the 380/385 processor board.

The repo is a fresh `Template_MiSTer` copy with the project renamed to `HP9K385`. It has one commit: the plan, the docs, and the CPU files vendored but not yet wired into the build.

**Read first, in this order:**
1. `docs/PLAN_385.md`: the overall plan, decisions log and phases. We are starting **Phase 0**.
2. `docs/reference/ap68040-integration.md`: CPU ports and bus protocol, plus the Mac-specific predicates in `rtl/wombat/wombat_cpu.sv` that must be parameterized.
3. `docs/reference/mame-hp380.md`: the HP 380 memory map and device register spec.
4. `docs/ROMS.md`: ROM files, checksums and byte order. The boot ROM must be word-swapped.
5. `docs/SITE_NOTES.md` and `docs/reference/legacy-hp300-core.md`: background only.

**Setup on this machine (check before doing anything):**
- `scratch/` should exist. It arrives as `scratch.zip`; unzip it in the repo root. It is git-ignored and holds the ROMs (`scratch/roms/`), the site mirror and the text extracts.
  - Verify the ROM SHA1s against `docs/ROMS.md`.
  - If `scratch/roms/hp9k380/bootrom_be.bin` is missing, regenerate it by swapping each byte pair of `1818-5062_98754_9000-380_27c210.bin`.
- Tools we need:
  - `iverilog`, `verilator` (5.x) and `vasmm68k_mot` (vbcc; set `VASM=` if it isn't on PATH).
  - Python 3.
  - Optionally `mame` with the `hp9k380`, `dio98550` and `human_interface` ROM sets, for reference traces.
  - Report anything that's missing and how to install it; don't guess around it.
- Sibling repos that may help, if present: `../MacQuadra800_MiSTer` (its `verilator/` is the model for our sim) and `../mame` (the device sources quoted in the docs). If they're absent, say so; the docs are meant to be self-sufficient.

**Phase 0 tasks:**
1. **CPU regression in this repo.** Make `rtl/ap68040/tb/run_tests.sh` pass here, unmodified if possible (all three legs). Don't edit files under `rtl/ap68040/`, which is vendored byte-identical. Put any wrappers or patches next to it, and note them in `docs/`.
2. **Parameterize `rtl/wombat/wombat_cpu.sv`.** Replace the Mac `cache_allow` and `c_post_ok`/`c_post_ok_hint` windows with module inputs or parameters:
   - Cacheable: RAM (top N MB below 0xFFFFFFFF) and the boot ROM 0x0-0x1FFFF.
   - Posted stores: RAM only.
   - Leave everything else in that file unchanged, and record the diff against the Quadra version in `docs/reference/ap68040-integration.md`.
3. **System top `rtl/hp385_top.sv`**, independent of MiSTer, so both Verilator and `HP9K385.sv` can instantiate it. Contents:
   - `wombat_cpu` + `wombat_bus32` and a simple address decoder.
   - Boot ROM, 128 KB, big-endian, loaded from a hex file in sim.
   - RAM at 0xFF800000-0xFFFFFFFF (8 MB; a behavioural array in sim).
   - 16 bytes of RAM at 0x5F4000.
   - The LED latch on writes to 0x1FFFC.
   - **BERR for every unmapped address.** The ROM probes for hardware by catching bus errors.
   - Stub out the PTM, 8042 and 98550 so they ack and return idle values for now. Interrupts are none yet; `ipl` = 7 (none pending).
   - Keep the CPU-side bus generic, because Phase 1 adds the DIO bridge.
4. **Verilator full-system sim** under `verilator/`, modelled on `../MacQuadra800_MiSTer/verilator/` but much smaller.
   - Headless first. Command-line flags select the ROM hex and the cycle limit.
   - Log the PC trace, every LED-latch write, every bus error (address, R/W, FC) and every access to the stub devices.
   - Add a Makefile target `make -C verilator run`.
5. **Reference trace.** Capture a MAME trace of `hp9k380` booting to compare with ours.
   - Use `mame hp9k380 -debug` with `trace`, or `-oslog` with a Lua script that logs PC and LED writes.
   - Compare **instruction streams and the sequence of probed addresses, not cycle counts**. MAME runs the CPU at 25 MHz and we run at 33 MHz.
   - Write a small Python diff tool in `verilator/` or `scripts/`.
   - If MAME isn't available, rely on the LED codes and the bus-error probe sequence.
6. Use the sim to answer, and record in `docs/`:
   - Which LED codes the ROM shows and where it stalls.
   - What it reads and writes at 0x5F4000.
   - How it sizes RAM.
   - Whether it reaches the "searching for console" stage, where it probes 0x560000 and select codes.
   - Find the ROM's checksum and RAM-test routines. Make a *sim-only* fast-boot patch script if they make the sim too slow (the legacy core did this for Rev D; the offsets differ for Rev 2.0).

**Milestone:** the Rev 2.0 boot ROM runs in Verilator through CPU self-test, RAM sizing and device probing, and stops at the first device we don't model yet. The LED sequence and probe list are documented, and the CPU test suite passes in this repo.

**Do not, in Phase 0:**
- Commit ROMs or anything from `scratch/`.
- Edit `sys/`.
- Enable the `AP040_EXPERIMENTAL_*` or `AP040_PIPELINE_*` macros.
- Start on the Catseye, SCSI or HIL.
- Run Quartus builds. The first real fit is at the end of Phase 1.

**Working style:**
- Commit in small steps with clear messages.
- Update the plan's decisions log when you make a design decision.
- At the end of the session, write `docs/RESUME-<date>-<topic>.md` for the next step.
