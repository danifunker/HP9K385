# AP68040 integration notes

Source: `../MacQuadra800_MiSTer` @ `011f7d9` (2026-10-10). Do not use `MacQuadra800-devel`, which is an older 2-commit snapshot from 2026-09-25 that lacks the A/UX `copyout`/MOVES fix (`e3fc1a0`) and the later FPU, ALU and muldiv work.

Vendored into this repo (files only, **not yet in `files.qip`**):

| Here | From Quadra |
|---|---|
| `rtl/ap68040/` (byte-identical, incl. `tb/`, `experimental/`, `doc/`) | `rtl/ap68040/` |
| `rtl/wombat/wombat_cpu.sv` | `rtl/wombat_cpu.sv` |
| `rtl/wombat/wombat_store_buffer.sv` | `rtl/wombat_store_buffer.sv` |
| `rtl/wombat/wombat_bus32.sv` | `rtl/wombat_bus32.sv` |
| `rtl/wombat/dpram.v` | `rtl/dpram.v`, the M10K-friendly altsyncram that replaces `rtl/ap68040/rtl/primitives/dpram.v` (sim stub) |

## Core facts

- **Origin:** Adam Polkosnik's AP68040 (from his Minimig-AGA_MiSTer fork), plus Alan Steremberg's performance work. GPL-2.0-or-later (`rtl/ap68040/LICENSE`, `UPSTREAM.md`).
- **Language and size:** plain Verilog-2001, about 17.8k lines.
  - `ap040_core.v` 10.5k lines, `ap040_fpu.v` 2.6k, `ap040_cache.v` 1.9k, `ap040_mmu.v` 0.9k.
  - File order is in `rtl/ap68040/rtl/ap040.qip`.
- **Proven on:** NetBSD/amiga, AmigaOS, Mac OS 7/8.1 and A/UX 3.1.
  - It passes 3776 of the 3801 slices of the WinUAE cputest 68040 corpus.
- **Integer unit:** the full 68000/010/020 ISA plus MOVE16, MOVEC, CINV/CPUSH/PFLUSH/PTEST.
  - Exception frames $0/$1/$2/$3/$7 (access error), with instruction restart.
- **MMU:** TC (4K/8K pages), URP/SRP, ITT0/1 and DTT0/1.
  - Split ATCs (16 sets x 4 ways), a hardware 3-level table walk, real PTEST/MMUSR and PFLUSH.
- **FPU:** the 040 subset in hardware: FMOVE/conversions, FABS/FNEG/FTST/FCMP, FADD/FSUB/FMUL/FDIV/FSQRT, FMOVEM, FSAVE/FRESTORE.
  - Transcendentals, FMOVECR, FINT, FMOD/FREM and packed decimal **trap to the FPSP** (vector 11 with a format $2 frame, or vector 55). This matches a real 040.
- **Caches:** split 8 KB I and 8 KB D, 4-way, 16-byte lines, physically tagged.
  - **Write-through only**, so CPUSH behaves as CINV.
  - There is a DMA snoop input (`snoop_stb`/`snoop_addr`).
- **Known gaps:**
  - TAS/CAS are not bus-locked.
  - **Interrupts are always autovectored** (`ipl_autovector` is ignored and there is no IACK cycle). This is fine for HP300.
  - No FPU BUSY frames.
  - Restart model only: WB1-3 are never marked valid.

## Ports and bus (`wombat_cpu.sv`)

- **Inputs:** `clk`, `nreset`, `ce`, `ipl[2:0]` (active low), `ipl_autovector`, `berr`, `stall_hold`, `store_buffer_ok`.
- **Retained-line sideband:** `cache_line_valid`/`tag[31:4]`/`data[127:0]`. Optional; tie it low.
- **Transaction bus:**
  - Out: `bus_req/write/instr/size[1:0]/addr/wdata/fc[2:0]`.
  - In: `bus_ack/rdata`.
- **Protocol:**
  - `req` is a held level and `ack` is a 1-cycle pulse. Data is right-aligned by size (B/W/L = 0/1/2).
  - Misaligned accesses come out unsplit; `wombat_bus32` splits them.
  - A line fill is 4 sequential longword beats with `req` held.
  - `berr` is a 1-cycle pulse that produces a format $7 frame.
  - `ap040_bus_timeout` turns a stuck access into an access error.
- **Other ports:**
  - Walker port: `walker_req/we/addr/wdat/ack/data/berr`.
  - Also `snoop_stb/addr`, `nresetout` (the RESET instruction), `cacr_out` and `vbr_out`.
- **Not** a real 040 TS/TA/TT/TM bus, so there is no dynamic bus sizing. The DIO bridge must split accesses for narrow ports.

### Mac-specific spots to parameterize in `wombat_cpu.sv`

- `cache_allow` (~line 411): Mac RAM/ROM windows. For HP300, use RAM (top N MB, below 0xFFFFFFFF) and the boot ROM. DIO, 0x5Fxxxx and VRAM must be uncached.
- `c_post_ok` / `c_post_ok_hint` (~lines 448-451): posted-store windows, including the DAFB $F90 VRAM. For HP300, use RAM only.
- Nothing functional inside `ap040_*` is Mac-specific.

## Clocks, area, timing

- **Quadra clocks:** `clk_sys` 33.000 MHz with `ce`=1, `clk_ram` 99 MHz (`sdram_beat32`, BL8 16-byte reads). This is exactly the 385's CPU clock.
- **Quadra totals:** ~39k/41.9k ALMs (93%), 468/553 M10K, 36 DSP. Timing closure is a seed lottery.
- **CPU share:** ~24.8k ALMs (core 22k, cache 2.2k, mmu 1.1k) with the release macros on.
- **Release macros** (Quadra `.qsf` ~609-623): `AP040_EXPERIMENTAL_{XSTORE,LEA,PIPELINE,PIPELINE_LOADS,PIPELINE_STORES,PIPELINE_PEA,PIPELINE_P6}`, `AP040_PIPELINE_{MEMORY_ENTRY,COMPARE,EARLY_DRAIN}`.
  - **Start with all of these OFF.**
  - `experimental/ap040_pipeline_integer.sv` is only needed when the pipeline macros are on.
- **Quadra performance:** Speedometer gives 75% of a real 33 MHz Quadra 800.

## Memory path worth copying later (not vendored yet)

- `rtl/sdram_beat32.sv` + `rtl/sdram.sv`: 99 MHz, BL8 line reads, 8-entry posted write FIFO, ~5 `clk_sys` read latency.
- Fast-path patterns in `rtl/quadra800.sv:577-690`: the first RAM miss bypasses `bus32`, beats 2-4 come from the retained line, direct write pushes. Copy the *pattern*, not the file, because Quadra decode is baked in.

## Tests

- `rtl/ap68040/tb/run_tests.sh` is standalone (iverilog + vasmm68k_mot): 35 asm programs plus unit benches. Run it here as the CPU regression.
- Quadra `verilator/` is Mac-bound but a good template for our full-system sim.
- Quadra `SingleStepTests/` has MAME-captured CPU/FPU/MMU JSON corpora that could be adapted.
