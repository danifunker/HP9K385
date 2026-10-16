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
//   --disk0 FILE / --disk1 FILE   SCSI disk images (IDs 0 / 1); writes go back to the file
//   --cd FILE          CD-ROM image on ID 2: flat 2048-byte sectors (an .iso), read-only
//   --key CYC:CODE     at clock CYC send HIL keycode CODE (hex; bit 0 = release); repeatable
//   --reset CYC        at clock CYC a 64-clock system reset (the OSD's Reset); repeatable
//   --mem-model M      main memory timing: ideal (default, MEM_LATENCY clocks a beat)
//                      or sdram (the measured sdram_beat32 timing, see mem_service)
//   --vram-latency N   98550 frame-buffer beat latency in clocks (default 2)
//   --ram-mb N         main RAM size, power of two, 1..128 (default 8)
//   --cycles N         stop after N clocks (default 50,000,000)
//   --patch OFF=VAL    sim-only ROM patch: 16-bit VAL at even byte OFF (hex);
//                      repeatable.
//   --log FILE         event log (default stdout)
//   --pc-trace FILE    one line per instruction dispatch: cycle pc opcode sr
//   --pc-trace-max N   stop the PC trace after N lines
//   --vram-trace FILE  one line per CPU access to the 98550 frame buffer
//                      ($200000-$3FFFFF): cycle pc R/W address be data acntl
//   --vram-trace-from CYC  ... starting at clock CYC
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
#include <ctime>
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

// ---- memory port: one request at a time ----
// "ideal" (default): every beat acks MEM_LATENCY clocks after the request.
// "sdram": the timing of the real path, rtl/mem/sdram_beat32.sv on
// rtl/mem/sdram.sv, as measured by the Quadra's tb_sdram against a chip
// model (same RTL): a read 6 clocks with its SDRAM row closed and 4 with it
// open, 1 clock for a longword of the 16-byte line the last read fetched (once
// its BL8 tail is in, 2 clocks after the critical word); a write is posted (1
// clock) into an eight-deep FIFO that drains one write per 2.45 clocks, and a
// read waits for the FIFO to empty; any write drops the line.  Rows are
// 1 KB, one open row per 8 MB bank.  The data itself is the same either way.
static const int MEM_LATENCY = 2;
static int mem_wait = -1;
static bool mem_sdram = false;
static bool     ln_valid = false;
static uint32_t ln_tag;              // SDRAM byte address >> 4
static uint64_t ln_ready;            // clock the line's BL8 tail is in
static int64_t  open_row[4] = {-1, -1, -1, -1};
static uint64_t wq_done[8];          // drain completion of queued writes, x100
static int      wq_n = 0;
static uint64_t wq_last = 0;         // x100: when the last queued write drains

static int mem_latency() {
	if (!mem_sdram) return MEM_LATENCY;
	uint32_t la = top->mem_addr << 2;
	uint32_t sa = top->mem_sel == 1 ? la - ram_base : (top->mem_sel == 0 ? 0x3FC0000 : 0x3FE0000) + (la & 0x1FFFF);
	uint64_t now = cycle * 100;
	while (wq_n && wq_done[0] <= now) { for (int i = 1; i < wq_n; i++) wq_done[i - 1] = wq_done[i]; wq_n--; }
	int bank = (sa >> 23) & 3;
	int64_t row = (sa >> 10) & 0x1FFF;
	if (top->mem_we) {
		ln_valid = false;
		uint64_t start = now;
		if (wq_n == 8) start = wq_done[0];             // full: wait for a slot
		wq_last = (wq_last > start ? wq_last : start) + 245;
		if (wq_n == 8) { for (int i = 1; i < 8; i++) wq_done[i - 1] = wq_done[i]; wq_n--; }
		wq_done[wq_n++] = wq_last;
		open_row[bank] = row;
		return (int)((start - now + 99) / 100) + 1;
	}
	if (ln_valid && (sa >> 4) == ln_tag && wq_n == 0)
		return ln_ready > cycle ? (int)(ln_ready - cycle) + 1 : 1;
	uint64_t start = now;
	if (wq_n && wq_last > start) start = wq_last;          // drain first
	if (ln_valid && ln_ready * 100 > start) start = ln_ready * 100;
	int lat = (int)((start - now + 99) / 100) + (open_row[bank] == row ? 4 : 6);
	open_row[bank] = row;
	ln_valid = true; ln_tag = sa >> 4; ln_ready = cycle + lat + 2;
	return lat;
}

static void mem_service() {
	top->mem_ack = 0;
	if (!top->mem_req) { mem_wait = -1; return; }
	if (mem_wait < 0) { mem_wait = mem_latency(); return; }
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
// (--vram-latency N: clocks per beat; the board's DDR3 path is slower than
// the default, which matters for software that does not wait for the mover)
static int vram_wait = -1;
static int vram_latency = MEM_LATENCY;

static void vram_service() {
	top->vram_ack = 0;
	if (!top->vram_req) { vram_wait = -1; return; }
	if (vram_wait < 0) { vram_wait = vram_latency; return; }
	if (--vram_wait > 0) return;
	vram_wait = -2;
	uint32_t o = (top->vram_addr << 2) & (vram.size() - 1);
	if (top->vram_we)
		for (int b = 0; b < 4; b++)
			if (top->vram_be & (8 >> b)) vram[o + b] = top->vram_wdata >> (24 - 8 * b);
	top->vram_rdata = be32(vram, o);
	top->vram_ack = 1;
}

// ---- SCSI disks: hps_io block protocol (WIDE: 16-bit words, [7:0] first) ----
struct Disk {
	FILE *f = nullptr;
	uint64_t size = 0;
};
static Disk disks[3];
static int blk_disk = -1;            // disk being served
static int blk_phase = 0;            // 0 idle, 1 latency, 2 streaming, 3 done
static int blk_wait = 0, blk_word = 0;
static bool blk_write = false;
static uint8_t blk_buf[512];

static void disk_service() {
	top->sd_buff_wr = 0;
	switch (blk_phase) {
	case 0:
		for (int d = 0; d < 3; d++) {
			bool rd = (top->sd_rd >> d) & 1, wr = (top->sd_wr >> d) & 1;
			if (!rd && !wr) continue;
			blk_disk = d; blk_write = wr; blk_wait = 64; blk_phase = 1; blk_word = 0;
			uint32_t lba = top->sd_lba[d];
			printf("[DISK%d] %s lba %u @%llu\n", d, wr ? "write" : "read", lba, (unsigned long long)cycle);
			memset(blk_buf, 0, 512);
			if (disks[d].f) {
				fseeko(disks[d].f, (off_t)lba * 512, SEEK_SET);
				if (!wr && fread(blk_buf, 1, 512, disks[d].f) != 512) { /* past the end: zeros */ }
				if (wr) fseeko(disks[d].f, (off_t)lba * 512, SEEK_SET);
			}
			break;
		}
		break;
	case 1:
		if (--blk_wait == 0) { top->sd_ack = 1 << blk_disk; blk_phase = 2; }
		break;
	case 2:
		if (!blk_write) {
			top->sd_buff_addr = blk_word;
			top->sd_buff_dout = blk_buf[2 * blk_word] | (blk_buf[2 * blk_word + 1] << 8);
			top->sd_buff_wr = 1;
			if (++blk_word == 256) blk_phase = 3;
		} else {
			// address now, sample the word on the next call
			if (blk_word > 0) {
				uint16_t w = (uint16_t)(top->sd_buff_din >> (16 * blk_disk));
				blk_buf[2 * (blk_word - 1)] = w & 0xFF; blk_buf[2 * (blk_word - 1) + 1] = w >> 8;
			}
			if (blk_word == 256) {
				if (disks[blk_disk].f) { fwrite(blk_buf, 1, 512, disks[blk_disk].f); fflush(disks[blk_disk].f); }
				blk_phase = 3;
			} else top->sd_buff_addr = blk_word;
			blk_word++;
		}
		break;
	case 3:
		top->sd_ack = 0;
		blk_phase = 4;
		break;
	case 4:
		// the request has to drop before the next one is taken
		if (!(((top->sd_rd | top->sd_wr) >> blk_disk) & 1)) blk_phase = 0;
		break;
	}
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
	const char *pct_path = nullptr, *fst_path = nullptr, *snap_path = nullptr, *vrt_path = nullptr;
	uint64_t vrt_from = 0;
	const char *hil_path = nullptr, *hilt_path = nullptr, *mlct_path = nullptr;
	const char *disk_path[3] = {nullptr, nullptr, nullptr};
	uint64_t snap_every = 0;
	bool rom_le = false;
	unsigned ram_mb = 8;
	uint64_t max_cycles = 50000000, fst_start = 0, fst_cycles = 1000000;
	uint64_t pct_max = UINT64_MAX, status_every = 10000000, loop_window = 2000000;
	int64_t stop_pc = -1;
	std::vector<std::pair<uint32_t, uint16_t>> patches;
	std::vector<std::pair<uint64_t, uint8_t>> keys;
	std::vector<uint64_t> resets;

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
		else if (a == "--disk0") disk_path[0] = next();
		else if (a == "--disk1") disk_path[1] = next();
		else if (a == "--cd") disk_path[2] = next();
		else if (a == "--ram-mb") ram_mb = strtoul(next(), nullptr, 0);
		else if (a == "--cycles") max_cycles = strtoull(next(), nullptr, 0);
		else if (a == "--log") log_path = next();
		else if (a == "--pc-trace") pct_path = next();
		else if (a == "--pc-trace-max") pct_max = strtoull(next(), nullptr, 0);
		else if (a == "--vram-trace") vrt_path = next();
		else if (a == "--vram-trace-from") vrt_from = strtoull(next(), nullptr, 0);
		else if (a == "--stop-pc") stop_pc = strtoll(next(), nullptr, 16);
		else if (a == "--vram-latency") vram_latency = (int)strtol(next(), nullptr, 0);
		else if (a == "--mem-model") { std::string m = next(); mem_sdram = (m == "sdram");
			if (m != "sdram" && m != "ideal") { fprintf(stderr, "--mem-model: ideal or sdram\n"); return 1; } }
		else if (a == "--loop-window") loop_window = strtoull(next(), nullptr, 0);
		else if (a == "--fst") fst_path = next();
		else if (a == "--fst-start") fst_start = strtoull(next(), nullptr, 0);
		else if (a == "--fst-cycles") fst_cycles = strtoull(next(), nullptr, 0);
		else if (a == "--status") status_every = strtoull(next(), nullptr, 0);
		else if (a == "--snap") snap_path = next();
		else if (a == "--snap-every") snap_every = strtoull(next(), nullptr, 0);
		else if (a == "--reset") resets.push_back(strtoull(next(), nullptr, 0));
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

	for (int d = 0; d < 3; d++) {
		if (!disk_path[d]) continue;
		disks[d].f = fopen(disk_path[d], d == 2 ? "rb" : "r+b");
		if (!disks[d].f) { perror(disk_path[d]); return 1; }
		fseeko(disks[d].f, 0, SEEK_END);
		disks[d].size = ftello(disks[d].f);
		printf("[SIM] SCSI %d: %s, %llu bytes\n", d, disk_path[d], (unsigned long long)disks[d].size);
	}

	FILE *log = log_path ? fopen(log_path, "w") : stdout;
	FILE *pct = pct_path ? fopen(pct_path, "w") : nullptr;
	FILE *vrt = vrt_path ? fopen(vrt_path, "w") : nullptr;
	FILE *hilt = hilt_path ? fopen(hilt_path, "w") : nullptr;
	FILE *mlct = mlct_path ? fopen(mlct_path, "w") : nullptr;
	if (!log || (pct_path && !pct)) { perror("log"); return 1; }

	top = new Vhp385_top;
	VerilatedFstC *fst = nullptr;
	if (fst_path) { Verilated::traceEverOn(true); fst = new VerilatedFstC; top->trace(fst, 99); fst->open(fst_path); }

	top->ram_mask = (0xFFF << lg) & 0xFFF;
	top->uart_rxd = 1; top->uart_cts_n = 0; top->uart_dsr_n = 0; top->uart_dcd_n = 0;

	// RTC seed: host local time in hps_io's MSM6242B BCD layout
	{
		time_t now = time(nullptr);
		struct tm *lt = localtime(&now);
		auto bcd = [](int v) -> uint64_t { return (uint64_t)(((v / 10) << 4) | (v % 10)); };
		uint64_t r = bcd(lt->tm_sec) | bcd(lt->tm_min) << 8 | bcd(lt->tm_hour) << 16 | bcd(lt->tm_mday) << 24 |
		             bcd(lt->tm_mon + 1) << 32 | bcd(lt->tm_year % 100) << 40 | (uint64_t)lt->tm_wday << 48;
		top->rtc_set[0] = (uint32_t)r;
		top->rtc_set[1] = (uint32_t)(r >> 32);
		top->rtc_set[2] = 0;
	}
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
		for (auto r : resets) {
			if (cycle == r) { top->reset = 1; printf("[RESET] @%llu\n", (unsigned long long)cycle); }
			if (cycle == r + 64) top->reset = 0;
		}
		if (cycle == reset_clks + 16) top->rtc_set[2] = 1;     // bit 64: "RTC updated"
		// mount the images: a one-clock pulse per disk with its size
		top->img_mounted = 0;
		for (int d = 0; d < 3; d++)
			if (disks[d].f && cycle == reset_clks + 20 + d) { top->img_mounted = 1 << d; top->img_size = disks[d].size; }
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
		disk_service();
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

		if (vrt && CATS(cpu_ack) && cycle >= vrt_from)
			fprintf(vrt, "%llu %08X %c %06X be=%X %08X acntl=%04X\n", (unsigned long long)cycle, pc,
			        CATS(cpu_we) ? 'W' : 'R', 0x200000 + ((uint32_t)CATS(cpu_addr) << 2), CATS(cpu_be),
			        CATS(cpu_we) ? CATS(cpu_wdata) : CATS(cpu_rdata), CATS(acntl));

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

		// 98644 serial output, a line at a time
		if (top->uart_tx_stb) {
			static std::string line;
			char c = (char)top->uart_tx_byte;
			if (c == '\n' || line.size() > 200) { printf("[SERIAL] %s\n", line.c_str()); line.clear(); }
			else if (c != '\r') line += (c >= 32 && c < 127) ? c : '.';
		}

		if (top->leds != last_leds) {
			printf("[LED] %02X  @%llu pc=%08X disp=%llu\n", top->leds, (unsigned long long)cycle, pc,
			       (unsigned long long)dispatches);
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
