# CPU baseline (AP68040 in the HP9K385 core)

Reference point for CPU experiments, measured 2026-10-14 at commit `b5b772c`
(Catseye pattern RAMs and UPI-41 data RAM in block memory; SCSI still three
targets). The CPU is `rtl/ap68040`, vendored byte-identical (see
`rtl/ap68040/UPSTREAM.md`), behind `wombat_cpu`, `wombat_bus32` and
`wombat_store_buffer`, built with no `AP040_*` macros, at 33 MHz.

To reproduce:

```
tools/cpubench/build.sh                     # build/hp385_cpubench.img (CACHE=0 for caches off)
cd verilator && make && make out/bootrom_fast.bin
./obj_dir/Vhp385_top --rom out/bootrom_fast.bin --card-rom ../scratch/roms/dio98550/98550a.bin \
    --hil-rom ../scratch/roms/human_interface/1820-4784.bin --disk0 <copy of the image> \
    --mem-model sdram --cycles 300000000 --loop-window 0 --stop-pc FFF0007E --log /dev/null > run.log
python3 -I ../scripts/cpubench_report.py run.log
scripts/cpu_regression.sh
```

The stop PC is the benchmark's final `bra.s .done` (`FFF0007E` with caches,
`FFF0004C` with `CACHE=0`; see `build/cpubench/bench.lst`). The boot to the
benchmark takes about 110M clocks of ROM self-test and SCSI scan.

## Area (Quartus 17.0, 5CSEBA6U23I7)

Full compile of `b5b772c` plus `FITTER_AGGRESSIVE_ROUTABILITY_OPTIMIZATION
ALWAYS` (now in `HP9K385.qsf`). Without that setting the same netlist placed
but failed routing on congestion at 89%.

| | Used | Of |
|---|---:|---:|
| ALMs | 37,019 (88%) | 41,910 |
| Registers | 25,013 | |
| Block memory bits | 736,705 (13%) | 5,662,720 |
| DSP blocks | 45 (40%) | 112 |

Fitter ALMs per entity (own logic in brackets):

| Entity | ALMs |
|---|---:|
| `wombat_cpu` (all of the CPU) | 23,698 |
| `ap040_core` | 20,228 (14,328) |
| `ap040_fpu` | 4,344 |
| `ap040_cache` | 2,096 |
| `ap040_mmu` | 1,162 |
| `ap040_alu` | 970 |
| `ap040_muldiv` | 363 |
| `ap040_regfile` | 222 |
| `wombat_bus32` | 177 |
| `wombat_store_buffer` | 154 |
| `hp385_top` (whole machine) | 29,263 |
| `emu` (machine plus shell glue) | 30,421 |

The CPU is 81% of the machine and 57% of the device. The rest of the
device is the MiSTer framework (ascal scaler 1,934, OSD, HDMI, audio).
The SCSI targets in this build are still three copies (1,645 ALMs); they
were merged later (`e5aa731`).

Analysis & Synthesis, per entity (combinational ALUTs / registers / block
memory bits / DSP):

| Entity | ALUTs | Registers | Block bits | DSP |
|---|---:|---:|---:|---:|
| `wombat_cpu` (all of the CPU) | 34,898 | 7,809 | 296,832 | 12 |
| `ap040_core` (own logic) | 20,902 | 4,055 | | |
| `ap040_fpu` | 6,798 | 1,387 | | 9 |
| `ap040_cache` | 3,197 | 581 | 291,328 | |
| `ap040_mmu` | 1,636 | 1,012 | 5,504 | |
| `ap040_alu` | 1,392 | 0 | | |
| `ap040_muldiv` | 636 | 301 | | 3 |
| `ap040_regfile` | 172 | 156 | (MLAB) | |
| `wombat_bus32` | 268 | 174 | | |
| `wombat_store_buffer` | 64 | 270 | | |
| `hp385_top` (whole machine) | 43,927 | 12,373 | 352,448 | 12 |

The CPU is about 79% of the machine's ALUTs.

## Timing

Slow 1100 mV 85 C model (the only corner this flow analyses).

| Clock | Setup slack | Fmax |
|---|---:|---:|
| `clk_sys` 33.33 MHz (CPU, machine) | +1.118 ns | 34.58 MHz |
| `clk_ram` 99 MHz (SDRAM) | +0.658 ns | 105.9 MHz |
| HDMI | +0.101 ns | |

Hold: worst +0.246 ns, all clocks met.

The worst `clk_sys` paths are `sdram_beat32`'s half-cycle handoff from
`clk_ram` (`line_done_handoff` -> `line_data`, +1.118 ns). The worst path
inside `clk_sys` is the CPU's prefetch queue, `ap040_core` `epf_data[0]` ->
`epf_data[4]` (+1.382 ns, about 28.9 ns of logic): the CPU alone would run
at about 34.6 MHz, so there is little headroom above 33 MHz.

## Correctness

`scripts/cpu_regression.sh` (the vendored AP68040 self-test suite): all three
legs pass, 34 checks each: `base` (what this core builds), `opt`
(`CPU_TEST_LEA=1 CPU_TEST_XSTORE=1`) and `release` (`CPU_TEST_RELEASE=1`).
It takes about 17 minutes on this machine with the legs in parallel.

The benchmark's integer checksums match an independent Python model of each
kernel. The FPU checksum is the same under both memory models but has no
independent reference.

## Performance (tools/cpubench, simulated)

Clocks are 33 MHz `clk_sys`. "instr" is the core's dispatch count, which is
not quite an architectural instruction count: BRANCH dispatches 7% more with
the caches on than with them off, so some re-dispatches are counted.

Memory models (`verilator/sim_main.cpp`):
- `sdram`: the measured `sdram_beat32` timing (read 6 clocks with the row
  closed, 4 open, 1 within the last line read; posted writes draining at 2.45
  clocks each). This is the hardware-like number.
- `ideal`: every beat 2 clocks (the sim's old default).

| Kernel | What | sdram clocks | instr | CPI | ideal clocks | caches off, sdram |
|---|---|---:|---:|---:|---:|---:|
| ALU | 20,000 x 9 register ops | 240,391 | 200,025 | 1.20 | 240,398 | 240,337 |
| BRANCH | 10,000 LFSR steps: bsr/rts, data-dependent branches | 337,881 | 107,352 | 3.15 | 337,886 | 410,048 |
| MULDIV | 4,000 x mulu.l, muls.l, divu.l, divs.l | 376,199 | 76,024 | 4.95 | 376,205 | 384,238 |
| L1READ | sum 1 KB x 200 (cache hits) | 169,831 | 58,223 | 2.92 | 169,895 | 514,217 |
| L1COPY | copy 1 KB x 100 | 156,834 | 29,738 | 5.27 | 182,498 | 541,893 |
| STREAD | sum 512 KB once | 1,375,669 | 147,480 | 9.33 | 1,407,353 | 1,311,968 |
| STWRITE | fill 512 KB | 789,626 | 164,380 | 4.80 | 920,763 | 789,708 |
| MEMCPY | copy 256 KB | 887,997 | 74,268 | 11.96 | 937,214 | 1,379,538 |
| CHASE | 8,192 dependent loads, 256-byte stride | 262,331 | 24,600 | 10.66 | 254,141 | 131,293 |
| FPU | 3,000 x fadd, fmul, fdiv, fsqrt (extended) | 237,222 | 27,031 | 8.78 | 237,226 | 234,255 |
| ICACHE | 8 KB straight-line code x 20 | 105,544 | 82,004 | 1.29 | 105,990 | 105,749 |
| **Total** | | **4,939,525** | 991,125 | **4.98** | 5,169,569 | 6,043,244 |

The PTM ticks printed on screen agree with the simulator's clocks (ALU:
0x71C ticks x 132 = 240,240 clocks).

### What stands out

- **A data-cache miss costs about 32 clocks**, against 4-6 for the memory
  itself (plus 1 for each further longword of the line). CHASE runs twice as
  fast with the caches off (16 clocks a hop uncached, 32 cached), and STREAD
  is slightly faster uncached. The cost is in the refill path between
  `ap040_cache`, `wombat_bus32` and the machine's bus FSM, not in SDRAM.
- **Cache-hit loads average 2.9 clocks per instruction** (L1READ, an
  `add.l (a0)+,d7` loop), where an MC68040 needs about 1.
- **The data cache is write-through by design** (AP040 README), so every
  store goes to memory even when the TTRs ask for copyback. Under the sdram
  model's posted writes, stores cost about 1 clock at the bus.
- **The I-cache gives little on straight-line code**: ICACHE runs at the same
  1.29 CPI with the caches on or off, so sequential fetch already keeps up.
  It does help loops (BRANCH is 21% slower without it).
- Register ALU work runs at 1.2 CPI; MULDIV and FPU are dominated by their
  multi-cycle units.
