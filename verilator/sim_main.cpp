// HP9K385 headless full-system simulation.
//
// Drives rtl/hp385_top.sv: serves its ROM/RAM/card-ROM memory port from
// host arrays and logs what the boot ROM does -- the instruction stream,
// LED-latch writes, exceptions, every bus error and every access to a stub
// device or the $5F4000 system registers.
//
//   obj_dir/Vhp385_top --rom bootrom_be.bin [options]
//
//   --rom FILE         boot ROM, big-endian CPU view (docs/ROMS.md)
//   --rom-le           the ROM file is MAME's little-endian word order
//   --card-rom FILE    98550A card ROM (byte stream); absent = 0xFF
//   --hil-rom FILE     8042 firmware 1820-4784 (2 KB); absent = the 8042 runs NOPs
//   --hil-trace FILE   one line per 8042 instruction: cycle pc a
//   --mlc-trace FILE   HIL link controller writes, reads and loop frames
//   --key CYC:CODE     at clock CYC send HIL keycode CODE (hex; bit 0 = release); repeatable
//   --ram-mb N         main RAM size, power of two, 1..128 (default 8)
//   --cycles N         stop after N clocks (default 50,000,000)
//   --patch OFF=VAL    sim-only ROM patch: 16-bit VAL at even byte OFF (hex);
//                      repeatable.
//   --log FILE         event log (default stdout)
//   --pc-trace FILE    one line per instruction dispatch: cycle pc opcode sr
//   --pc-trace-max N   stop the PC trace after N lines
//   --stop-pc ADDR     stop when an instruction at ADDR is dispatched (hex)
//   --loop-window N    stall/stuck-loop detector window in clocks (default 2M; 0 off)
//   --fst FILE         FST waveform, from --fst-start for --fst-cycles clocks
//   --status N         print a progress line every N clocks (default 10M)
//   --snap FILE        write the 98550A screen (1280x1024 PPM) at the end
//   --snap-every N     ... and every N clocks

#include "Vhp385_top.h"
#include "Vhp385_top___024root.h"
#include "verilated.h"
#include "verilated_fst_c.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#define CORE(sig) (top->rootp->hp385_top__DOT__cpu__DOT__core__DOT__##sig)
#define CATS(sig) (top->rootp->hp385_top__DOT__catseye__DOT__##sig)
#define UPI(sig) (top->rootp->hp385_top__DOT__hil__DOT__cpu__DOT__##sig)
#define TOP(sig) (top->rootp->hp385_top__DOT__##sig)
#define NEREID(sig) (top->rootp->hp385_top__DOT__nereid__DOT__##sig)

static Vhp385_top *top;
static uint64_t cycle;

static std::vector<uint8_t> rom(128 * 1024, 0xFF);
static std::vector<uint8_t> card(32 * 1024, 0xFF);
static std::vector<uint8_t> hilrom(2048, 0x00);
static std::vector<uint8_t> ram;
static std::vector<uint8_t> vram(4 << 20, 0);   // 98550A: video bank, overlay bank
static uint32_t ram_base;

static bool load(const char *path, std::vector<uint8_t> &dst, bool swap16) {
	FILE *f = fopen(path, "rb");
	if (!f) { perror(path); return false; }
	size_t n = fread(dst.data(), 1, dst.size(), f);
	fclose(f);
	if (n != dst.size()) fprintf(stderr, "warning: %s: read %zu of %zu bytes\n", path, n, dst.size());
	if (swap16)
		for (size_t i = 0; i + 1 < dst.size(); i += 2) std::swap(dst[i], dst[i + 1]);
	return true;
}

static uint32_t be32(const std::vector<uint8_t> &m, uint32_t off) {
	return (uint32_t)m[off] << 24 | (uint32_t)m[off + 1] << 16 | (uint32_t)m[off + 2] << 8 | m[off + 3];
}

// ---- memory port: fixed latency, one request at a time ----
static const int MEM_LATENCY = 2;
static int mem_wait = -1;

static void mem_service() {
	top->mem_ack = 0;
	if (!top->mem_req) { mem_wait = -1; return; }
	if (mem_wait < 0) { mem_wait = MEM_LATENCY; return; }
	if (--mem_wait > 0) return;
	mem_wait = -2;   // acked; wait for mem_req to drop
	uint32_t la = top->mem_addr << 2;
	uint32_t rd = 0xFFFFFFFF;
	switch (top->mem_sel) {
	case 0:
		if (!top->mem_we) rd = be32(rom, la & (rom.size() - 1));
		break;
	case 1: {
		uint32_t o = la - ram_base;
		if (o < ram.size()) {
			if (top->mem_we) {
				for (int b = 0; b < 4; b++)
					if (top->mem_be & (8 >> b)) ram[o + b] = top->mem_wdata >> (24 - 8 * b);
			}
			rd = be32(ram, o);
		}
		break;
	}
	case 2:
		rd = be32(card, la & (card.size() - 1));
		break;
	}
	top->mem_rdata = rd;
	top->mem_ack = 1;
}

// ---- 98550A VRAM port: same handshake as the memory port ----
static int vram_wait = -1;

static void vram_service() {
	top->vram_ack = 0;
	if (!top->vram_req) { vram_wait = -1; return; }
	if (vram_wait < 0) { vram_wait = MEM_LATENCY; return; }
	if (--vram_wait > 0) return;
	vram_wait = -2;
	uint32_t o = (top->vram_addr << 2) & (vram.size() - 1);
	if (top->vram_we)
		for (int b = 0; b < 4; b++)
			if (top->vram_be & (8 >> b)) vram[o + b] = top->vram_wdata >> (24 - 8 * b);
	top->vram_rdata = be32(vram, o);
	top->vram_ack = 1;
}

// Screen as the 98550A shows it: display-enabled planes through the Nereid
static void snapshot(const char *path) {
	FILE *f = fopen(path, "wb");
	if (!f) { perror(path); return; }
	fprintf(f, "P6\n1280 1024\n255\n");
	uint8_t de = top->display_enable, pm = NEREID(plane_mask), oc = NEREID(overlay_ctl);
	std::vector<uint8_t> line(1280 * 3);
	for (int y = 0; y < 1024; y++) {
		for (int x = 0; x < 1280; x++) {
			uint8_t v = vram[y * 2048 + x] & de, o = vram[(2 << 20) + y * 2048 + x] & de & oc;
			uint32_t rgb = NEREID(clut)[o ? (0x100 | (o & pm)) : (v & pm)];
			line[x * 3] = rgb >> 16; line[x * 3 + 1] = rgb >> 8; line[x * 3 + 2] = rgb;
		}
		fwrite(line.data(), 1, line.size(), f);
	}
	fclose(f);
}

static const char *kind_name[] = {"BERR", "STUB", "SYS ", "LED ", "ROMW", "IO8 ", "IO16", "?"};

static const char *region_name(uint32_t a) {
	if (a < 0x20000) return "bootrom";
	if (a >= 0x00200000 && a < 0x00400000) return "98550-vram";
	if ((a >> 16) == 0x42) return "8042";
	if ((a >> 16) == 0x47) return "hpib";
	if (a >= 0x00500000 && a < 0x00500210) return "dma";
	if (a >= 0x00564000 && a < 0x00564900) return "catseye";
	if (a >= 0x00566000 && a < 0x00566100) return "nereid";
	if ((a >> 16) == 0x56) return "98550";
	if ((a >> 4) == 0x005F400) return "sysregs";
	if ((a >> 4) == 0x005F800) return "ptm";
	if (a == 0x0041C000 || (a >> 12) == 0x41C) return "frodo(4xx)";
	if (a >= 0x00600000 && a < 0x01000000) {
		static char buf[32];
		snprintf(buf, sizeof buf, "dio-sc%u", (a - 0x00600000) >> 16);
		return buf;
	}
	if (a >= 0x01000000 && a < 0x20000000) return "dio-ii";
	if (a >= 0xF0000000) return "ram-probe";
	return "";
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	const char *rom_path = nullptr, *card_path = nullptr, *log_path = nullptr;
	const char *pct_path = nullptr, *fst_path = nullptr, *snap_path = nullptr;
	const char *hil_path = nullptr, *hilt_path = nullptr, *mlct_path = nullptr;
	uint64_t snap_every = 0;
	bool rom_le = false;
	unsigned ram_mb = 8;
	uint64_t max_cycles = 50000000, fst_start = 0, fst_cycles = 1000000;
	uint64_t pct_max = UINT64_MAX, status_every = 10000000, loop_window = 2000000;
	int64_t stop_pc = -1;
	std::vector<std::pair<uint32_t, uint16_t>> patches;
	std::vector<std::pair<uint64_t, uint8_t>> keys;

	for (int i = 1; i < argc; i++) {
		std::string a = argv[i];
		auto next = [&]() -> const char * {
			if (i + 1 >= argc) { fprintf(stderr, "%s needs a value\n", a.c_str()); exit(2); }
			return argv[++i];
		};
		if (a == "--rom") rom_path = next();
		else if (a == "--rom-le") rom_le = true;
		else if (a == "--card-rom") card_path = next();
		else if (a == "--hil-rom") hil_path = next();
		else if (a == "--hil-trace") hilt_path = next();
		else if (a == "--mlc-trace") mlct_path = next();
		else if (a == "--ram-mb") ram_mb = strtoul(next(), nullptr, 0);
		else if (a == "--cycles") max_cycles = strtoull(next(), nullptr, 0);
		else if (a == "--log") log_path = next();
		else if (a == "--pc-trace") pct_path = next();
		else if (a == "--pc-trace-max") pct_max = strtoull(next(), nullptr, 0);
		else if (a == "--stop-pc") stop_pc = strtoll(next(), nullptr, 16);
		else if (a == "--loop-window") loop_window = strtoull(next(), nullptr, 0);
		else if (a == "--fst") fst_path = next();
		else if (a == "--fst-start") fst_start = strtoull(next(), nullptr, 0);
		else if (a == "--fst-cycles") fst_cycles = strtoull(next(), nullptr, 0);
		else if (a == "--status") status_every = strtoull(next(), nullptr, 0);
		else if (a == "--snap") snap_path = next();
		else if (a == "--snap-every") snap_every = strtoull(next(), nullptr, 0);
		else if (a == "--key") {
			const char *v = next();
			const char *c = strchr(v, ':');
			if (!c) { fprintf(stderr, "--key CYC:CODE\n"); return 2; }
			keys.push_back({strtoull(v, nullptr, 0), (uint8_t)strtoul(c + 1, nullptr, 16)});
		}
		else if (a == "--patch") {
			const char *v = next();
			const char *eq = strchr(v, '=');
			if (!eq) { fprintf(stderr, "--patch OFF=VAL\n"); return 2; }
			patches.push_back({(uint32_t)strtoul(v, nullptr, 16), (uint16_t)strtoul(eq + 1, nullptr, 16)});
		}
		else if (a[0] == '+') continue;   // verilator plusargs
		else { fprintf(stderr, "unknown option %s\n", a.c_str()); return 2; }
	}
	if (!rom_path) { fprintf(stderr, "--rom is required\n"); return 2; }
	if (!load(rom_path, rom, rom_le)) return 1;
	if (card_path && !load(card_path, card, false)) return 1;
	if (hil_path && !load(hil_path, hilrom, false)) return 1;
	for (auto &p : patches) {
		if (p.first + 1 >= rom.size() || (p.first & 1)) { fprintf(stderr, "bad patch offset %x\n", p.first); return 2; }
		rom[p.first] = p.second >> 8; rom[p.first + 1] = p.second & 0xFF;
		printf("[PATCH] rom[%05X] = %04X\n", p.first, p.second);
	}
	if (ram_mb < 1 || ram_mb > 128 || (ram_mb & (ram_mb - 1))) { fprintf(stderr, "--ram-mb must be a power of two 1..128\n"); return 2; }
	ram.assign((size_t)ram_mb << 20, 0);
	ram_base = (uint32_t)(0x100000000ull - ((uint64_t)ram_mb << 20));
	unsigned lg = __builtin_ctz(ram_mb);

	FILE *log = log_path ? fopen(log_path, "w") : stdout;
	FILE *pct = pct_path ? fopen(pct_path, "w") : nullptr;
	FILE *hilt = hilt_path ? fopen(hilt_path, "w") : nullptr;
	FILE *mlct = mlct_path ? fopen(mlct_path, "w") : nullptr;
	if (!log || (pct_path && !pct)) { perror("log"); return 1; }

	top = new Vhp385_top;
	VerilatedFstC *fst = nullptr;
	if (fst_path) { Verilated::traceEverOn(true); fst = new VerilatedFstC; top->trace(fst, 99); fst->open(fst_path); }

	top->ram_mask = (0xFFF << lg) & 0xFFF;
	top->ce = 1;
	top->reset = 1;
	top->clk = 0;
	top->mem_ack = 0;
	top->mem_rdata = 0;
	printf("[SIM] ROM %s%s, RAM %u MB at %08X (mask %03X), SSP=%08X PC=%08X\n",
	       rom_path, rom_le ? " (swapped)" : "", ram_mb, ram_base, top->ram_mask, be32(rom, 0), be32(rom, 4));

	uint8_t last_leds = 0xFF;
	bool last_toggle = false, last_in_exc = false;
	uint64_t pct_lines = 0, dispatches = 0;
	uint32_t win_lo = 0xFFFFFFFF, win_hi = 0, prev_lo = 1, prev_hi = 0;
	uint64_t win_events = 0, prev_events = 1, win_dispatches = 0;
	uint32_t last_ev_addr = 0xFFFFFFFF; uint8_t last_ev_kind = 0xFF, last_ev_be = 0; bool last_ev_wr = false;
	uint64_t ev_repeat = 0;
	int exc_report = -1;
	bool gfx_warned = false;      // clocks until the pending exception is logged
	const char *stop_reason = "cycle limit";

	// reset: the first 2048 clocks also load the 8042 firmware
	const uint64_t reset_clks = 2048 + 16;
	for (cycle = 0; cycle < max_cycles; cycle++) {
		if (cycle < 2048) {
			top->hil_rom_wr = 1; top->hil_rom_addr = cycle; top->hil_rom_data = hilrom[cycle];
		} else top->hil_rom_wr = 0;
		if (cycle == reset_clks) top->reset = 0;
		top->hil_key_stb = 0;
		for (auto &k : keys)
			if (k.first == cycle) {
				top->hil_key_stb = 1; top->hil_key_code = k.second;
				printf("[KEY] %02X @%llu\n", k.second, (unsigned long long)cycle);
			}
		top->clk = 1;
		top->eval();
		mem_service();       // sample the outputs of this edge, answer for the next
		vram_service();
		top->eval();
		if (fst && cycle >= fst_start && cycle < fst_start + fst_cycles) fst->dump(cycle * 2);
		top->clk = 0;
		top->eval();
		if (fst && cycle >= fst_start && cycle < fst_start + fst_cycles) fst->dump(cycle * 2 + 1);
		if (top->reset) continue;

		// a port request that is never answered is a harness/protocol bug
		static uint64_t vreq_since = 0;
		if (!top->vram_req) vreq_since = cycle;
		else if (cycle - vreq_since == 1000)
			printf("[VRAM] request held 1000 clocks: addr=%06X we=%u wait=%d es=%u @%llu\n",
			       top->vram_addr << 2, top->vram_we, vram_wait, CATS(es), (unsigned long long)cycle);

		uint32_t pc = CORE(pc_i);

#define HILC(sig) (top->rootp->hp385_top__DOT__hil__DOT__##sig)
		if (mlct) {
			if (HILC(mlc_wr)) fprintf(mlct, "%llu W r%u %02X%s\n", (unsigned long long)cycle, HILC(mlc_reg), HILC(p1_out),
			                          HILC(mlc_reg) == 0 ? " (frame)" : "");
			if (HILC(mlc_wr) && HILC(mlc_reg) == 0) fprintf(mlct, "%llu   frame %03X\n", (unsigned long long)cycle, HILC(wr_frame));
			if (HILC(push)) fprintf(mlct, "%llu   loop -> MLC %03X\n", (unsigned long long)cycle, HILC(push_frame));
			if (HILC(p1_rd) && HILC(hil_read)) fprintf(mlct, "%llu R r%u = %02X\n", (unsigned long long)cycle, HILC(mlc_reg), HILC(mlc_dout));
		}
		if (hilt && UPI(dbg_dispatch)) {
			// registers of the active bank (R0-R7 at 0 or 24) and loop-state RAM
			const unsigned rb = (UPI(psw) & 0x10) ? 24 : 0;
			fprintf(hilt, "%llu %03X %02X r2=%02X r6=%02X 6A=%02X 6B=%02X\n", (unsigned long long)cycle, UPI(dbg_pc), UPI(a),
			        UPI(ram)[rb + 2], UPI(ram)[rb + 6], UPI(ram)[0x6A], UPI(ram)[0x6B]);
		}

		bool toggle = CORE(perf_dispatch_toggle);
		if (toggle != last_toggle) {
			last_toggle = toggle;
			dispatches++;
			if (pc < win_lo) win_lo = pc;
			if (pc > win_hi) win_hi = pc;
			if (pct && pct_lines < pct_max) {
				fprintf(pct, "%llu %08X %04X %04X\n", (unsigned long long)cycle, pc, CORE(ir), CORE(sr));
				pct_lines++;
			}
			if (stop_pc >= 0 && pc == (uint32_t)stop_pc) { stop_reason = "stop-pc"; break; }
		}

		// in_exc rises as stacking starts; the vector/frame registers are
		// settled a few clocks later
		bool in_exc = CORE(in_exc);
		if (in_exc && !last_in_exc) exc_report = 4;
		last_in_exc = in_exc;
		if (exc_report >= 0 && exc_report-- == 0)
			fprintf(log, "%12llu EXC  vec=%3u fmt=%X spc=%08X addr=%08X pc_i=%08X sr=%04X vbr=%08X\n",
			        (unsigned long long)cycle, CORE(exc_vec), CORE(exc_fmt), CORE(exc_spc),
			        CORE(exc_addr), pc, CORE(sr), CORE(vbr));

		if (top->ev_stb) {
			win_events++;
			uint32_t a = top->ev_addr;
			if (a == last_ev_addr && top->ev_kind == last_ev_kind && top->ev_be == last_ev_be &&
			    top->ev_write == last_ev_wr && top->ev_kind != 3) {
				ev_repeat++;
			} else {
				if (ev_repeat) fprintf(log, "%12s      (previous line repeated %llu more times)\n", "", (unsigned long long)ev_repeat);
				ev_repeat = 0;
				last_ev_addr = a; last_ev_kind = top->ev_kind; last_ev_be = top->ev_be; last_ev_wr = top->ev_write;
				fprintf(log, "%12llu %s %c %08X be=%X data=%08X fc=%u%s pc=%08X %s\n",
				        (unsigned long long)cycle, kind_name[top->ev_kind & 7], top->ev_write ? 'W' : 'R',
				        a, top->ev_be, top->ev_data, top->ev_fc, top->ev_walker ? " walker" : "",
				        pc, region_name(a));
			}
		}

		if (top->leds != last_leds) {
			printf("[LED] %02X  @%llu pc=%08X\n", top->leds, (unsigned long long)cycle, pc);
			if (log != stdout) fprintf(log, "%12llu LED  %02X\n", (unsigned long long)cycle, top->leds);
			last_leds = top->leds;
		}

		if (top->cpu_halted) { stop_reason = "CPU halted (double fault)"; break; }

		if (top->gfx_unsupported && !gfx_warned) {
			printf("[GFX] unsupported Catseye operation (line draw or bit mode) @%llu pc=%08X\n",
			       (unsigned long long)cycle, pc);
			gfx_warned = true;
		}
		if (snap_path && snap_every && cycle % snap_every == 0) snapshot(snap_path);

		if (status_every && cycle % status_every == 0)
			printf("[STATUS] %llu clocks, %llu dispatches, pc=%08X leds=%02X\n",
			       (unsigned long long)cycle, (unsigned long long)dispatches, pc, top->leds);

		if (loop_window && cycle % loop_window == 0) {
			if (dispatches == win_dispatches) {
				// nothing dispatched for a whole window: STOP with no
				// interrupt source, or a bus access nobody answers
				printf("[STALL] no instruction dispatched for %llu clocks, pc=%08X ir=%04X sr=%04X\n",
				       (unsigned long long)loop_window, pc, CORE(ir), CORE(sr));
				stop_reason = CORE(ir) == 0x4E72 ? "STOP with no interrupt" : "CPU stalled";
				break;
			}
			// stuck: two windows in a row executing the same small PC range
			// with no new events
			if (win_lo == prev_lo && win_hi == prev_hi && win_hi - win_lo < 0x100 &&
			    win_events == 0 && prev_events == 0) {
				printf("[LOOP] stuck in %08X-%08X since ~%llu\n", win_lo, win_hi,
				       (unsigned long long)(cycle - 2 * loop_window));
				stop_reason = "stuck loop";
				break;
			}
			prev_lo = win_lo; prev_hi = win_hi; prev_events = win_events;
			win_lo = 0xFFFFFFFF; win_hi = 0; win_events = 0;
			win_dispatches = dispatches;
		}
	}
	if (ev_repeat) fprintf(log, "%12s      (previous line repeated %llu more times)\n", "", (unsigned long long)ev_repeat);

	printf("[SIM] stop: %s at %llu clocks (%.3f s at 33 MHz), %llu dispatches, pc=%08X leds=%02X\n",
	       stop_reason, (unsigned long long)cycle, cycle / 33e6, (unsigned long long)dispatches,
	       (uint32_t)CORE(pc_i), top->leds);
	printf("[SIM] bus svc=%u vr_cpu_req=%u mem_req=%u vram_req=%u | catseye es=%u col=%u line=%u w=%u h=%u src=%u dst=%u\n",
	       TOP(svc), TOP(vr_cpu_req), top->mem_req, top->vram_req, CATS(es), CATS(m_col), CATS(m_line),
	       CATS(wm_w), CATS(wm_h), CATS(m_need_src), CATS(m_need_dst));
	if (snap_path) { snapshot(snap_path); printf("[SIM] screen -> %s\n", snap_path); }
	if (fst) { fst->close(); delete fst; }
	if (pct) fclose(pct);
	if (hilt) fclose(hilt);
	if (mlct) fclose(mlct);
	if (log != stdout) fclose(log);
	top->final();
	delete top;
	return 0;
}
