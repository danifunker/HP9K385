# HP9K385 headless full-system simulation (Verilator).
#   make            build obj_dir/Vhp385_top
#   make run        boot the Rev 2.0 ROM: ROM=<big-endian boot ROM> CYCLES=<n>
#   make clean
# ROM images are never committed; by default they are read from ../scratch/roms
# (docs/ROMS.md).  Logs land in out/ (git-ignored).
V    = verilator
RTL  = ../rtl
AP   = ../rtl/ap68040/rtl

ROM      ?= ../scratch/roms/hp9k380/bootrom_be.bin
CARDROM  ?= ../scratch/roms/dio98550/98550a.bin
CYCLES   ?= 50000000
RUNARGS  ?=

V_SRC = \
	hp385.vlt \
	$(RTL)/hp385_top.sv \
	$(RTL)/ptm6840.sv \
	$(RTL)/catseye.sv \
	$(RTL)/nereid.sv \
	$(RTL)/wombat/wombat_cpu.sv \
	$(RTL)/wombat/wombat_store_buffer.sv \
	$(RTL)/wombat/wombat_bus32.sv \
	$(AP)/ap040_core.v \
	$(AP)/ap040_bus_timeout.v \
	$(AP)/ap040_regfile.v \
	$(AP)/ap040_alu.v \
	$(AP)/ap040_muldiv.v \
	$(AP)/ap040_mmu.v \
	$(AP)/ap040_cache.v \
	$(AP)/ap040_fpu.v \
	$(AP)/primitives/dpram.v

C_SRC = sim_main.cpp

V_WARN = -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-IMPLICIT \
	-Wno-PINMISSING -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE \
	-Wno-UNSIGNED -Wno-CMPCONST -Wno-LATCH -Wno-UNDRIVEN -Wno-MISINDENT \
	-Wno-COMBDLY -Wno-INITIALDLY -Wno-SYNCASYNCNET -Wno-BLKLOOPINIT \
	-Wno-MULTIDRIVEN -Wno-GENUNNAMED
# --unroll-count: ap040_mmu.v clears its 128 ATC valid flops in a for loop;
# above Verilator's default of 64 it is not unrolled and PFLUSHA silently
# becomes a no-op (found in the NeXT-Color core, noted in the Quadra Makefile).
V_OPT = -O3 --x-assign fast --x-initial fast --noassert --unroll-count 256 \
	--trace-fst --threads 1
V_FLAGS = -cc --exe --build -j 0 --Mdir obj_dir --top-module hp385_top \
	+define+SIMULATION=1 -I$(AP) $(V_WARN) $(V_OPT) \
	-CFLAGS "-O2 -g" -o Vhp385_top

EXE = obj_dir/Vhp385_top

all: $(EXE)

$(EXE): $(V_SRC) $(C_SRC) Makefile
	$(V) $(V_FLAGS) $(V_SRC) $(C_SRC)

run: $(EXE)
	@mkdir -p out
	$(EXE) --rom $(ROM) --card-rom $(CARDROM) --cycles $(CYCLES) \
		--log out/events.log --pc-trace out/pc.log --snap out/screen.ppm $(RUNARGS)

clean:
	rm -rf obj_dir out

.PHONY: all run clean
