//============================================================================
//  wombat_cpu — AP68040 bundled for the Quadra 800's flat 32-bit bus.
//
//  Same core+MMU+cache wiring as ap040_tg68k_compat (the configuration the
//  silicon campaign validated), minus the 16-bit Minimig bus adapter: the
//  post-cache 32-bit transaction port is exported directly for djMEMC.
//
//  Bus contract (same as ap040_bus16_adapter's core side):
//   - bus_req is level-held; during a cache line fill it stays high across
//     the 4 beats with bus_addr changing, so consumers must re-accept on
//     req && !their-own-ack, never on a req edge.
//   - bus_ack is a single-cycle pulse with bus_rdata valid (right-aligned
//     by bus_size); wdata is right-aligned by size.
//   - Misaligned word/long transactions appear here unsplit; the consumer
//     (wombat_bus32) splits them into aligned beats.
//   - berr is a single-cycle pulse while the transaction is in flight.
//============================================================================

`include "ap040_defs.svh"

module wombat_cpu
#(
	parameter AP040_HAS_FPU      = 1,
	parameter AP040_ENABLE_CACHE = 1,
	parameter AP040_STORE_BUFFER = 1
)
(
	input         clk,
	input         nreset,
	input         ce,

	input   [2:0] ipl,            // active low
	input         ipl_autovector,
	input         berr,
	// Hold the core-side stall watchdog while the platform has a block
	// transfer outstanding: a pseudo-DMA beat legitimately waits for the
	// HPS then, and a busy SD card (the Main writes images O_SYNC) or an
	// open OSD stalls it for far longer than any bus-error budget.
	input         stall_hold,
	output        dbg_stall_flt, // the watchdog fired (for the SCSI tracer)

	// Optional completed physical RAM line retained by the platform.
	input         cache_line_valid,
	input  [31:4] cache_line_tag,
	input [127:0] cache_line_data,
	// High only when low physical addresses select non-faulting RAM.
	input         store_buffer_ok,

	// post-cache 32-bit transaction bus (physical addresses)
	output        bus_req,
	output        bus_write,
	output        bus_instr,
	output  [1:0] bus_size,       // AP040_SZ_B/W/L
	output [31:0] bus_addr,
	output [31:0] bus_wdata,
	output  [2:0] bus_fc,
	input         bus_ack,
	input  [31:0] bus_rdata,

	// MMU table-walker port (physical, aligned longwords)
	output        walker_req,
	output        walker_we,
	output [31:0] walker_addr,
	output [31:0] walker_wdat,
	input         walker_ack,
	input  [31:0] walker_data,
	input         walker_berr,

	// DMA write snoop (SONIC later; tie off until then)
	input         snoop_stb,
	input  [31:0] snoop_addr,

	output        nresetout,
	output        nmi_ack_toggle,
	output [31:0] cacr_out,
	output [31:0] vbr_out,
	output        debug_busy,
	output        debug_fault,
	output        debug_halted,
	output [255:0] debug_status,
	output [127:0] debug_status2
);

// core to MMU
wire        mem_req;
wire        mem_write;
wire        mem_instr;
wire  [1:0] mem_size;
wire [31:0] mem_addr;
wire [31:0] mem_hint_addr, mm_hint_addr;
wire        mem_hint_away, mem_fast_ready, mem_ack_q;
wire        mem_hint_instr, mm_hint_instr, mm_hint_match, mm_hint_wmatch;
wire [21:0] mm_hint_ptag;
wire [31:0] mem_ihint_addr, mm_ihint_addr;   // the instruction hint bus (P175)
wire [21:0] mm_ihint_ptag;
wire        mm_ihint_match;
wire [31:0] mem_wdata;
wire  [2:0] mem_fc;
wire        mem_ack;

// ---- P171: two request channels from the core, one port into the MMU ----
// The core keeps the fetch queue's requests (ifr_*) apart from its data
// requests (mem_*), so a data request can be issued and hinted while a
// fetch is outstanding.  One channel is presented to the MMU/cache at a
// time; a presented request is never switched until it completes; when
// both wait, the data request goes first (the CPU is stalled on it, the
// fetch is speculative).  Acknowledge and fault return to the presented
// channel only; the platform's berr belongs to it as well.
wire        ifr_req, ifr_ack, ifr_flt, ifr_berr;
wire [31:0] ifr_addr;
wire  [1:0] ifr_size;
wire  [2:0] ifr_fc;
wire        core_req, core_write, core_instr;   // the data channel as the core drives it
wire  [1:0] core_size;
wire [31:0] core_addr, core_wdata;
wire  [2:0] core_fc;
wire        core_ack, core_flt, core_berr;
reg         pres_v, pres_instr;
// P184: a fetch in its first presented clock that the instruction hint
// carried the clock before (row and word) is served by the instruction
// mirrors (fast_ihit); the architectural banks stay on the data hint then,
// so the data side's idle read is not lost to every one-clock fetch.  If
// the fetch does not hit, the cache holds its registered lookup for that
// clock and the banks follow the fetch from the next (pres_v).
reg   [9:0] ihint_q;
always @(posedge clk) ihint_q <= mem_ihint_addr[11:2];
wire        ifetch_hinted_first = !pres_v && (ihint_q == ifr_addr[11:2]);
wire        sel_instr = pres_v ? pres_instr : !core_req;
// The MMU's W_DROP state (and the original core's exception entry) rely
// on a request-low cycle after a fault before the next request is seen;
// with two channels the other one would otherwise take the port in the
// very next cycle and c_req would never fall.
reg         flt_gap;
assign mem_req   = !flt_gap && (sel_instr ? ifr_req  : core_req);
assign mem_write = sel_instr ? 1'b0     : core_write;
assign mem_instr = sel_instr;
assign mem_size  = sel_instr ? ifr_size : core_size;
assign mem_addr  = sel_instr ? ifr_addr : core_addr;
assign mem_wdata = core_wdata;
assign mem_fc    = sel_instr ? ifr_fc   : core_fc;
wire        p_done = mem_ack | mem_flt | berr;
assign core_ack = mem_ack && !sel_instr;
assign ifr_ack  = mem_ack &&  sel_instr;
// MMU faults and bus errors stay separate (the frame's ATC bit), each
// delivered to the channel presented when it happened.
assign core_flt  = mem_flt && !sel_instr;
assign ifr_flt   = mem_flt &&  sel_instr;
assign core_berr = berr    && !sel_instr;
assign ifr_berr  = berr    &&  sel_instr;
always @(posedge clk) begin
	if (!nreset) begin pres_v <= 0; pres_instr <= 0; flt_gap <= 0; end
	else begin
		flt_gap <= p_done && (mem_flt | berr);
		if (pres_v) begin
			if (p_done) pres_v <= 0;
		end
		else if (mem_req && !p_done) begin
			pres_v <= 1; pres_instr <= sel_instr;
		end
	end
end
wire [31:0] mem_rdata;
wire        mem_flt_mmu;

// Core-side stall watchdog, from ap040_tg68k_compat: a request lost below
// the core would otherwise hang it with no fault frame.  Two changes from
// the verbatim 2^21 (63 ms at 33 MHz), 2026-09-03: the request is hidden
// from the watchdog while stall_hold says the platform is busy with a block
// transfer (the Mac OS 8.1 installer's write bursts stalled pseudo-DMA
// beats past 63 ms on SD-card housekeeping and the resulting bus error
// inside the SCSI Manager's DMA loop showed up as a hung or failed install),
// and the budget is 2^24 (0.5 s) so nothing short of a genuine wedge fires
// it.  The IOSB's own 7.9 ms escape for an idle SDMA beat still fires first.
wire        core_stall_flt;
assign dbg_stall_flt = core_stall_flt;
ap040_bus_timeout #(.COUNTER_BITS(24)) core_stall_watchdog (
	.clk(clk),
	.nreset(nreset),
	.req(mem_req && !stall_hold),
	.complete(mem_ack | mem_flt_mmu),
	.berr(core_stall_flt)
);
wire        mem_flt = mem_flt_mmu | core_stall_flt;

// MMU to cache
wire        mm_req, mm_write, mm_instr;
wire  [1:0] mm_size;
wire [31:0] mm_addr, mm_wdata;
wire  [2:0] mm_fc;
wire        mm_ack, mm_nocache;
wire [31:0] mm_rdata;
wire        mm_line_stb, mem_line_stb, mm_busy;
wire [31:4] mm_line_tag, mem_line_tag;
wire [127:0] mm_line_data, mem_line_data;

// MMU walker requests are held behind older buffered CPU stores. This matters
// when software writes a page-table entry and immediately incurs an ATC miss:
// the walker must not observe memory before that store has reached the platform.
wire        mmu_walker_req, mmu_walker_we;
wire [31:0] mmu_walker_addr, mmu_walker_wdat;

// Cache/no-cache master side before the ordered write buffer.
wire        cpu_bus_req, cpu_bus_write, cpu_bus_instr;
wire  [1:0] cpu_bus_size;
wire [31:0] cpu_bus_addr, cpu_bus_wdata;
wire  [2:0] cpu_bus_fc;
wire        cpu_bus_ack;
wire        cpu_bus_posted;
wire [31:0] cpu_bus_rdata;
wire        buffered_store_pending;

// CINV sideband
wire        cinv_req, cinv_ic, cinv_dc, cinv_done;

// control registers and PTEST/PFLUSH sideband
wire [31:0] w_tc, w_urp, w_srp, w_itt0, w_itt1, w_dtt0, w_dtt1;
wire        pt_req, pt_write, pt_done;
wire [31:0] pt_addr, pt_mmusr;
wire  [2:0] pt_fcw;
wire        pf_req, pf_done;
wire  [1:0] pf_mode;
wire [31:0] pf_addr;
wire  [2:0] pf_fcw;

ap040_core #(
	.AP040_HAS_MMU(1),
	.AP040_HAS_FPU(AP040_HAS_FPU),
	.AP040_ENABLE_CACHE(AP040_ENABLE_CACHE),
	.AP040_FAST_SIM(0)
) core (
	.clk(clk),
	.nreset(nreset),
	.ce(ce),

	.mem_req(core_req),
	.mem_write(core_write),
	.mem_instr(core_instr),
	.mem_size(core_size),
	.mem_addr(core_addr),
	.mem_hint_addr(mem_hint_addr),
	.mem_hint_instr(mem_hint_instr),
	.mem_hint_away(mem_hint_away),
	.mem_fast_ready(mem_fast_ready),
	.mem_ack_q(mem_ack_q),
	.mem_ihint_addr(mem_ihint_addr),
	.mem_wdata(core_wdata),
	.mem_fc(core_fc),
	.mem_ack(core_ack),
	.ifr_req(ifr_req), .ifr_addr(ifr_addr), .ifr_size(ifr_size), .ifr_fc(ifr_fc),
	.ifr_ack(ifr_ack), .ifr_flt(ifr_flt), .ifr_berr(ifr_berr), .ifr_pres(sel_instr),
	.mem_rdata(mem_rdata),
	.mem_line_stb(mem_line_stb),
	.mem_line_tag(mem_line_tag),
	.mem_line_data(mem_line_data),
	.mem_flt(core_flt),

	.tc_out(w_tc),
	.urp_out(w_urp),
	.srp_out(w_srp),
	.itt0_out(w_itt0),
	.itt1_out(w_itt1),
	.dtt0_out(w_dtt0),
	.dtt1_out(w_dtt1),
	.pt_req(pt_req),
	.pt_write(pt_write),
	.pt_addr(pt_addr),
	.pt_fc(pt_fcw),
	.pt_done(pt_done),
	.pt_mmusr(pt_mmusr),
	.pf_req(pf_req),
	.pf_mode(pf_mode),
	.pf_addr(pf_addr),
	.pf_fc(pf_fcw),
	.pf_done(pf_done),
	.cinv_req(cinv_req),
	.cinv_ic(cinv_ic),
	.cinv_dc(cinv_dc),
	.cinv_done(cinv_done),

	.ipl(ipl),
	.ipl_autovector(ipl_autovector),
	.berr(core_berr),
	.nmi_ack_toggle(nmi_ack_toggle),

	.nresetout(nresetout),
	.cacr_out(cacr_out),
	.vbr_out(vbr_out),

	.debug_busy(debug_busy),
	.debug_fault(debug_fault),
	.debug_halted(debug_halted),
	.debug_status(debug_status),
	.debug_status2(debug_status2)
);

ap040_mmu mmu (
	.clk(clk),
	.nreset(nreset),
	.ce(ce),

	.tc(w_tc),
	.urp(w_urp),
	.srp(w_srp),
	.itt0(w_itt0),
	.itt1(w_itt1),
	.dtt0(w_dtt0),
	.dtt1(w_dtt1),

	.c_req(mem_req),
	.c_write(mem_write),
	.c_instr(mem_instr),
	.c_size(mem_size),
	.c_addr(mem_addr),
	.c_hint_addr(mem_hint_addr),
	.c_hint_instr(mem_hint_instr),
	.c_ihint_addr(mem_ihint_addr),
	.c_wdata(mem_wdata),
	.c_fc(mem_fc),
	.c_ack(mem_ack),
	.c_rdata(mem_rdata),
	.c_line_stb(mem_line_stb),
	.c_line_tag(mem_line_tag),
	.c_line_data(mem_line_data),
	.c_flt(mem_flt_mmu),

	.pt_req(pt_req),
	.pt_write(pt_write),
	.pt_addr(pt_addr),
	.pt_fc(pt_fcw),
	.pt_done(pt_done),
	.pt_mmusr(pt_mmusr),

	.pf_req(pf_req),
	.pf_mode(pf_mode),
	.pf_addr(pf_addr),
	.pf_fc(pf_fcw),
	.pf_done(pf_done),

	.m_req(mm_req),
	.m_write(mm_write),
	.m_instr(mm_instr),
	.m_size(mm_size),
	.m_addr(mm_addr),
	.m_hint_addr(mm_hint_addr),
	.m_hint_instr(mm_hint_instr),
	.m_hint_ptag(mm_hint_ptag),
	.m_hint_match(mm_hint_match),
	.m_hint_wmatch(mm_hint_wmatch),
	.m_ihint_addr(mm_ihint_addr),
	.m_ihint_ptag(mm_ihint_ptag),
	.m_ihint_match(mm_ihint_match),
	.m_wdata(mm_wdata),
	.m_fc(mm_fc),
	.m_ack(mm_ack),
	.m_rdata(mm_rdata),
	.m_line_stb(mm_line_stb),
	.m_line_tag(mm_line_tag),
	.m_line_data(mm_line_data),

	.walker_req(mmu_walker_req),
	.walker_we(mmu_walker_we),
	.walker_addr(mmu_walker_addr),
	.walker_wdat(mmu_walker_wdat),
	.walker_ack(walker_ack),
	.walker_data(walker_data),
	.walker_berr(walker_berr),

	.phys_addr(),
	.cache_inhibit(),
	.m_nocache(mm_nocache)
);

assign walker_req  = mmu_walker_req && !buffered_store_pending && !mm_busy;
assign walker_we   = mmu_walker_we;
assign walker_addr = mmu_walker_addr;
assign walker_wdat = mmu_walker_wdat;

// Walker U/M-bit writes invalidate any cached copy of the descriptor —
// same one-slot pending scheme as ap040_tg68k_compat (audit 5.5 there).
reg         wsnp_pend;
reg  [31:0] wsnp_addr;
reg         walker_wr_d;
wire        walker_wr_edge = (walker_req & walker_we) & ~walker_wr_d;

always @(posedge clk) begin
	if (!nreset) begin
		walker_wr_d <= 1'b0;
		wsnp_pend   <= 1'b0;
		wsnp_addr   <= 32'd0;
	end
	else begin
		walker_wr_d <= walker_req & walker_we;
		if (walker_wr_edge) begin
			wsnp_pend <= 1'b1;
			wsnp_addr <= walker_addr;
		end
		else if (wsnp_pend && !snoop_stb)
			wsnp_pend <= 1'b0;
	end
end

wire        snp_stb  = snoop_stb | wsnp_pend;
wire [31:0] snp_addr = snoop_stb ? snoop_addr : wsnp_addr;

generate
if (AP040_ENABLE_CACHE != 0) begin : g_cache
	// Quadra 800 physical cacheability: RAM space (djMEMC banks,
	// $00000000-$3FFFFFFF) and the ROM window ($40000000-$4FFFFFFF) may be
	// cached; IOSB I/O, DAFB VRAM/registers and NuBus must never be.  With
	// translation on, the MMU's CM attributes (mm_nocache) still override.
	wire cache_allow = (mm_addr[31:30] == 2'b00) || (mm_addr[31:28] == 4'h4);

	ap040_cache cache (
		.clk(clk),
		.nreset(nreset),
		.ce(ce),

		.ie(cacr_out[15]),
		.de(cacr_out[31]),

		.cinv_req(cinv_req),
		.cinv_ic(cinv_ic),
		.cinv_dc(cinv_dc),
		.cinv_done(cinv_done),

		.c_req(mm_req),
		.c_write(mm_write),
		.c_instr(mm_instr),
		.c_size(mm_size),
		.c_addr(mm_addr),
		.c_hint_addr(mm_hint_addr),
		.c_hint_instr(mm_hint_instr),
		.c_hint_ptag(mm_hint_ptag),
		.c_hint_match(mm_hint_match),
		.c_hint_wmatch(mm_hint_wmatch),
		.c_hint_away(mem_hint_away),
		.c_fast_ready(mem_fast_ready),
		.c_ack_q(mem_ack_q),
		.c_ihint_addr(mm_ihint_addr),
		.c_ihint_ptag(mm_ihint_ptag),
		.c_ihint_match(mm_ihint_match),
		.c_ihold(mem_req && sel_instr && !ifetch_hinted_first),
		.c_wdata(mm_wdata),
		.c_fc(mm_fc),
		.c_nocache(mm_nocache | ~cache_allow),
		// same qualifier as wombat_store_buffer's buffer_req
		// same qualifier as wombat_store_buffer's buffer_req: RAM and the DAFB VRAM window
		.c_post_ok_hint(store_buffer_ok && ((mm_hint_ptag[21:20] == 2'b00) ||
		                                    (mm_hint_ptag[21:11] == 11'b1111_1001_000))),
		.c_post_ok(store_buffer_ok && ((mm_addr[31:30] == 2'b00) ||
		                               (mm_addr[31:21] == 11'b1111_1001_000))),
		.s_stb(snp_stb),
		.s_addr(snp_addr),
		.c_ack(mm_ack),
		.c_rdata(mm_rdata),
		.c_line_stb(mm_line_stb),
		.c_line_tag(mm_line_tag),
		.c_line_data(mm_line_data),
		.c_busy(mm_busy),
		.m_posted(cpu_bus_posted),

		.m_req(cpu_bus_req),
		.m_write(cpu_bus_write),
		.m_instr(cpu_bus_instr),
		.m_size(cpu_bus_size),
		.m_addr(cpu_bus_addr),
		.m_wdata(cpu_bus_wdata),
		.m_fc(cpu_bus_fc),
		.m_ack(cpu_bus_ack),
		.m_rdata(cpu_bus_rdata),
		// A retained line predating a queued store is stale until the
		// write reaches the platform and invalidates that lower-level line.
		.m_line_valid(cache_line_valid && !buffered_store_pending),
		.m_line_tag(cache_line_tag),
		.m_line_data(cache_line_data),
		.m_err(berr)
	);
end
else begin : g_nocache
	assign cpu_bus_req   = mm_req;
	assign cpu_bus_write = mm_write;
	assign cpu_bus_instr = mm_instr;
	assign cpu_bus_size  = mm_size;
	assign cpu_bus_addr  = mm_addr;
	assign cpu_bus_wdata = mm_wdata;
	assign cpu_bus_fc    = mm_fc;
	assign mm_ack        = cpu_bus_ack;
	assign mm_rdata      = cpu_bus_rdata;
	assign mm_line_stb = 1'b0;
	assign mm_line_tag = 28'd0;
	assign mm_line_data = 128'd0;
	assign mm_busy = 1'b0;
	assign cpu_bus_posted = 1'b0;
	assign cinv_done = 1'b1;
end
endgenerate

wombat_store_buffer #(.ENABLE(AP040_STORE_BUFFER)) store_buffer (
	.clk(clk),
	.nreset(nreset),
	.ce(ce),
	.buffer_writes(store_buffer_ok),

	.s_req(cpu_bus_req),
	.s_posted(cpu_bus_posted),
	.s_write(cpu_bus_write),
	.s_instr(cpu_bus_instr),
	.s_size(cpu_bus_size),
	.s_addr(cpu_bus_addr),
	.s_wdata(cpu_bus_wdata),
	.s_fc(cpu_bus_fc),
	.s_ack(cpu_bus_ack),
	.s_rdata(cpu_bus_rdata),

	.m_req(bus_req),
	.m_write(bus_write),
	.m_instr(bus_instr),
	.m_size(bus_size),
	.m_addr(bus_addr),
	.m_wdata(bus_wdata),
	.m_fc(bus_fc),
	.m_ack(bus_ack),
	.m_rdata(bus_rdata),
	.m_err(berr),
	.pending(buffered_store_pending)
);

endmodule
