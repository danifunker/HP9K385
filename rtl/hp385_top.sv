//============================================================================
//  hp385_top — HP 9000 Model 385 system, independent of the MiSTer shell.
//
//  Phase 0 scope: AP68040 (wombat_cpu) + wombat_bus32 + the HP 300 address
//  decoder.  Boot ROM, card ROM and main RAM are served through the generic
//  memory port below (a behavioural model in Verilator, SDRAM on the board).
//  Everything not decoded bus-errors: the boot ROM probes RAM size, select
//  codes and DIO-II space by catching bus errors.
//
//  Memory map (docs/PLAN_385.md §1):
//    $00000000-$0001FFFF  boot ROM (mem port, sel 0); write $1FFFC = LEDs
//    $00420000-$0042FFFF  8042 HIL controller          (stub)
//    $00470000-$0047FFFF  built-in HP-IB + status      (stub)
//    $00560000-$0056FFFF  98550A: card ROM on odd bytes (mem port, sel 2),
//                         Catseye regs $564000, Nereid $566000 (stub)
//    $005F4000-$005F400F  system-control registers (16 bytes of RAM, as MAME)
//    $005F8000-$005F800F  MC6840 PTM (ptm6840.sv), IRQ 6
//    top N MB below $FFFFFFFF  main RAM (mem port, sel 1), N from ram_mask
//
//  Memory port contract (same shape as wombat_bus32's beat side):
//    mem_req is level-held until mem_ack (a one-cycle pulse; mem_rdata valid
//    with it).  mem_addr is a longword address; mem_be[3] = byte at +0.
//    sel 0 = boot ROM, 1 = RAM, 2 = 98550A card ROM.  For sel 2, mem_addr
//    is the longword index into the 32 KB card-ROM byte stream (read only).
//
//  The trace port pulses ev_stb for every bus error, stub-device access,
//  system-register access and LED write, so the sim can log the probe order.
//  8-bit devices sit on the odd bytes (D7:0 of each 16-bit word, so lanes 2
//  and 0 of a longword beat).  A beat is served one odd lane at a time
//  through the io8_* strobe, so a longword or MOVEP access to them behaves
//  like the 030's dynamic bus sizing would have; even lanes read 0xFF.
//
//  ce must be 1 for now (the decoder is not ce-gated).
//============================================================================

module hp385_top
(
	input             clk,
	input             reset,
	input             ce,

	input      [11:0] ram_mask,       // see wombat_cpu: 12'hFF8 = 8 MB

	// ROM/RAM port
	output reg        mem_req,
	output reg  [1:0] mem_sel,        // 0 boot ROM, 1 RAM, 2 card ROM
	output reg        mem_we,
	output reg [31:2] mem_addr,
	output reg  [3:0] mem_be,
	output reg [31:0] mem_wdata,
	input             mem_ack,
	input      [31:0] mem_rdata,

	output reg  [7:0] leds,

	// trace port
	output reg        ev_stb,
	output reg  [2:0] ev_kind,
	output reg [31:0] ev_addr,        // longword address of the beat
	output reg  [3:0] ev_be,
	output reg        ev_write,
	output reg [31:0] ev_data,        // write data, or the read data returned
	output reg  [2:0] ev_fc,
	output reg        ev_walker,

	output            cpu_halted,
	output            cpu_reset_out   // RESET instruction (active high)
);

localparam EV_BERR = 3'd0;
localparam EV_STUB = 3'd1;
localparam EV_SYS  = 3'd2;
localparam EV_LED  = 3'd3;
localparam EV_ROMW = 3'd4;   // write to boot ROM space other than the LEDs
localparam EV_IO8  = 3'd5;   // modelled 8-bit device access (data = result)

wire nreset = !reset;

//----------------------------------------------------------------------------
// CPU
//----------------------------------------------------------------------------
wire        bus_req, bus_write, bus_instr;
wire  [1:0] bus_size;
wire [31:0] bus_addr, bus_wdata;
wire  [2:0] bus_fc;
wire        bus_ack;
wire [31:0] bus_rdata;

wire        walker_req, walker_we;
wire [31:0] walker_addr, walker_wdat;
reg         walker_ack;
reg  [31:0] walker_data;
reg         walker_berr;

reg         cpu_berr;
wire        nresetout;
reg   [2:0] ipl_n;                // active low, from the priority encoder

wombat_cpu cpu (
	.clk(clk),
	.nreset(nreset),
	.ce(ce),

	.ipl(ipl_n),
	.ipl_autovector(1'b1),
	.berr(cpu_berr),
	.stall_hold(1'b0),
	.dbg_stall_flt(),

	.cache_line_valid(1'b0),
	.cache_line_tag(28'd0),
	.cache_line_data(128'd0),
	.store_buffer_ok(1'b1),
	.ram_mask(ram_mask),

	.bus_req(bus_req),
	.bus_write(bus_write),
	.bus_instr(bus_instr),
	.bus_size(bus_size),
	.bus_addr(bus_addr),
	.bus_wdata(bus_wdata),
	.bus_fc(bus_fc),
	.bus_ack(bus_ack),
	.bus_rdata(bus_rdata),

	.walker_req(walker_req),
	.walker_we(walker_we),
	.walker_addr(walker_addr),
	.walker_wdat(walker_wdat),
	.walker_ack(walker_ack),
	.walker_data(walker_data),
	.walker_berr(walker_berr),

	.snoop_stb(1'b0),
	.snoop_addr(32'd0),

	.nresetout(nresetout),
	.nmi_ack_toggle(),
	.cacr_out(),
	.vbr_out(),
	.debug_busy(),
	.debug_fault(),
	.debug_halted(cpu_halted),
	.debug_status(),
	.debug_status2()
);

assign cpu_reset_out = !nresetout;

wire        b_req, b_write;
wire [31:2] b_addr;
wire  [3:0] b_be;
wire [31:0] b_wdata;
reg         b_ack;
reg  [31:0] b_rdata;

wombat_bus32 bus32 (
	.clk(clk),
	.nreset(nreset),
	.ce(ce),

	.t_req(bus_req),
	.t_write(bus_write),
	.t_size(bus_size),
	.t_addr(bus_addr),
	.t_wdata(bus_wdata),
	.t_berr(cpu_berr),
	.t_ack(bus_ack),
	.t_rdata(bus_rdata),
	.t_active(),

	.b_req(b_req),
	.b_write(b_write),
	.b_addr(b_addr),
	.b_be(b_be),
	.b_wdata(b_wdata),
	.b_ack(b_ack),
	.b_rdata(b_rdata)
);

// Bus service state; walker requests take precedence over the CPU beat
localparam S_IDLE = 2'd0;
localparam S_MEM  = 2'd1;
localparam S_IO8  = 2'd2;

reg  [1:0]  svc;
reg         svc_walker;
reg  [31:2] svc_addr;
reg  [3:0]  svc_be;
reg         svc_write;
reg  [31:0] svc_wdata;
reg  [2:0]  svc_fc;
reg         svc_card_odd;         // card ROM: odd beat takes the low half
reg   [1:0] svc_dev;              // 8-bit device being served
reg   [1:0] io_pend;              // odd lanes still to do: [1] = +1, [0] = +3
reg  [31:0] io_rdata;
reg         walker_armed;
wire        walker_pend = walker_req && walker_armed;

// the beat (or walker access) about to be accepted
wire [31:2] s_addr  = walker_pend ? walker_addr[31:2] : b_addr;
wire [31:0] s_la    = {s_addr, 2'b00};
wire        s_write = walker_pend ? walker_we : b_write;
wire  [3:0] s_be    = walker_pend ? 4'b1111 : b_be;
wire [31:0] s_wdata = walker_pend ? walker_wdat : b_wdata;
wire        s_valid = walker_pend || (b_req && !b_ack && !cpu_berr);

//----------------------------------------------------------------------------
// Address decode (on a longword address)
//----------------------------------------------------------------------------
localparam R_BERR = 3'd0;
localparam R_MEM  = 3'd1;   // mem port: ROM/RAM/card ROM
localparam R_SYS  = 3'd2;   // $5F4000 registers
localparam R_STUB = 3'd3;   // idle device stub
localparam R_ROMW = 3'd4;   // write into boot ROM space (LED latch at $1FFFC)
localparam R_IO8  = 3'd5;   // modelled 8-bit odd-byte device (d_dev)

localparam DEV_PTM = 2'd0;

function [31:0] stub_rdata;   // idle read value of a stub device longword
	input [31:2] a;
	reg   [31:0] la;
	begin
		la = {a, 2'b00};
		stub_rdata = 32'h0000_0000;
		// built-in HP-IB block (odd bytes; docs/reference/mame-hp380.md)
		if (la[31:16] == 16'h0047) begin
			case (la[4:2])
				3'd0: stub_rdata = 32'h0080_0080;   // +1 ID 0x80, +3 status bit 7
				3'd1: stub_rdata = 32'h0081_0000;   // +5 0x81 (no KBD NMI)
				default: stub_rdata = 32'h0000_0000;
			endcase
		end
		// Catseye STATUS ($564800): ready + no daughterboard
		else if (la[31:2] == (32'h0056_4800 >> 2))
			stub_rdata = 32'h000A_0000;
	end
endfunction

reg  [2:0]  d_region;
reg  [1:0]  d_sel;
reg  [31:2] d_maddr;
reg  [31:0] d_stub;
reg   [1:0] d_dev;

always @(*) begin
	d_region = R_BERR;
	d_sel    = 2'd0;
	d_maddr  = s_addr;
	d_stub   = stub_rdata(s_addr);
	d_dev    = DEV_PTM;
	if (s_la[31:17] == 15'd0) begin
		if (s_write) d_region = R_ROMW;
		else begin d_region = R_MEM; d_sel = 2'd0; end
	end
	else if (&(s_la[31:20] | ~ram_mask)) begin
		d_region = R_MEM; d_sel = 2'd1;
	end
	else if (s_la[31:4] == 28'h005F400)
		d_region = R_SYS;
	else if (s_la[31:4] == 28'h005F800) begin  // MC6840 PTM
		d_region = R_IO8; d_dev = DEV_PTM;
	end
	else if (s_la[31:16] == 16'h0042)          // 8042
		d_region = R_STUB;
	else if (s_la[31:16] == 16'h0047)          // HP-IB
		d_region = R_STUB;
	else if (s_la[31:16] == 16'h0056) begin    // 98550A
		// card ROM bytes at odd addresses; Catseye/Nereid registers in
		// $564000-$5648FF and $566000-$5660FF override it
		if ((s_la[15:8] >= 8'h40 && s_la[15:8] <= 8'h48) || s_la[15:8] == 8'h60)
			d_region = R_STUB;
		else if (!s_write) begin
			// longword at $560000+4k carries card-ROM bytes 2k (lane 2)
			// and 2k+1 (lane 0): ask the port for the 16-bit pair at byte
			// index 2k, i.e. card-ROM longword k/2, half k[0]
			d_region = R_MEM; d_sel = 2'd2;
			d_maddr  = {16'd0, 1'b0, s_la[15:3]};
		end
		else
			d_region = R_STUB;
	end
end

//----------------------------------------------------------------------------
// 8-bit odd-byte devices
//----------------------------------------------------------------------------
wire        io8_cs    = (svc == S_IO8) && (|io_pend);
wire        io8_we    = svc_write;
wire [31:0] io8_addr  = {svc_addr, io_pend[1] ? 2'd1 : 2'd3};
wire  [7:0] io8_wdata = io_pend[1] ? svc_wdata[23:16] : svc_wdata[7:0];
wire  [7:0] ptm_dout;
wire        ptm_irq;

ptm6840 ptm (
	.clk(clk),
	.reset(reset),
	.cs(io8_cs && svc_dev == DEV_PTM),
	.we(io8_we),
	.rs(io8_addr[3:1]),
	.din(io8_wdata),
	.dout(ptm_dout),
	.irq(ptm_irq),
	.out()
);

wire  [7:0] io8_rdata = ptm_dout;

//----------------------------------------------------------------------------
// Interrupts: all autovectored; IPL is the highest pending level
//----------------------------------------------------------------------------
wire  [7:1] irq_lvl = {1'b0, ptm_irq, 5'b00000};
always @(posedge clk)
	if (reset) ipl_n <= 3'd7;
	else ipl_n <= irq_lvl[7] ? 3'd0 : irq_lvl[6] ? 3'd1 : irq_lvl[5] ? 3'd2 :
	         irq_lvl[4] ? 3'd3 : irq_lvl[3] ? 3'd4 : irq_lvl[2] ? 3'd5 :
	         irq_lvl[1] ? 3'd6 : 3'd7;

//----------------------------------------------------------------------------
// Bus service FSM
//----------------------------------------------------------------------------
reg  [31:0] sysreg [0:3];

function [31:0] merge_be;
	input [31:0] old;
	input [31:0] nw;
	input  [3:0] be;
	merge_be = {be[3] ? nw[31:24] : old[31:24], be[2] ? nw[23:16] : old[23:16],
	            be[1] ? nw[15:8]  : old[15:8],  be[0] ? nw[7:0]   : old[7:0]};
endfunction

task automatic complete;
	input        is_walker;
	input [31:0] data;
	begin
		if (is_walker) begin walker_ack <= 1; walker_data <= data; end
		else           begin b_ack <= 1;      b_rdata <= data;     end
	end
endtask

task automatic event_log;
	input  [2:0] kind;
	input [31:0] data;
	begin
		ev_stb    <= 1;
		ev_kind   <= kind;
		ev_addr   <= s_la;
		ev_be     <= s_be;
		ev_write  <= s_write;
		ev_data   <= data;
		ev_fc     <= walker_pend ? 3'd5 : bus_fc;
		ev_walker <= walker_pend;
	end
endtask

always @(posedge clk) begin
	b_ack       <= 0;
	walker_ack  <= 0;
	walker_berr <= 0;
	cpu_berr    <= 0;
	ev_stb      <= 0;
	if (!walker_req) walker_armed <= 1;

	if (reset) begin
		svc          <= S_IDLE;
		mem_req      <= 0;
		walker_armed <= 1;
		leds         <= 8'h00;
		sysreg[0] <= 0; sysreg[1] <= 0; sysreg[2] <= 0; sysreg[3] <= 0;
	end
	else case (svc)
	S_IDLE: if (s_valid) begin
		svc_walker <= walker_pend;
		if (walker_pend) walker_armed <= 0;
		case (d_region)
		R_MEM: begin
			mem_req     <= 1;
			mem_sel     <= d_sel;
			mem_we      <= s_write;
			mem_addr    <= d_maddr;
			mem_be      <= s_be;
			mem_wdata   <= s_wdata;
			svc_card_odd <= s_la[2];
			svc         <= S_MEM;
		end
		R_SYS: begin
			if (s_write) sysreg[s_la[3:2]] <= merge_be(sysreg[s_la[3:2]], s_wdata, s_be);
			complete(walker_pend, sysreg[s_la[3:2]]);
			event_log(EV_SYS, s_write ? s_wdata : sysreg[s_la[3:2]]);
		end
		R_IO8: begin
			svc_dev   <= d_dev;
			svc_addr  <= s_addr;
			svc_be    <= s_be;
			svc_write <= s_write;
			svc_wdata <= s_wdata;
			svc_fc    <= walker_pend ? 3'd5 : bus_fc;
			io_pend   <= {s_be[2], s_be[0]};
			io_rdata  <= 32'hFFFF_FFFF;
			svc       <= S_IO8;
		end
		R_STUB: begin
			complete(walker_pend, d_stub);
			event_log(EV_STUB, s_write ? s_wdata : d_stub);
		end
		R_ROMW: begin
			// LEDs take the odd byte of either half of $1FFFC
			if (s_la[16:2] == 15'h7FFF && (s_be[0] || s_be[2])) begin
				leds <= s_be[0] ? s_wdata[7:0] : s_wdata[23:16];
				event_log(EV_LED, s_wdata);
			end
			else
				event_log(EV_ROMW, s_wdata);
			complete(walker_pend, 32'hFFFF_FFFF);
		end
		default: begin
			if (walker_pend) walker_berr <= 1;
			else             cpu_berr    <= 1;
			event_log(EV_BERR, 32'hFFFF_FFFF);
		end
		endcase
	end
	S_MEM: if (mem_ack) begin
		mem_req <= 0;
		svc     <= S_IDLE;
		if (mem_sel == 2'd2)
			// card ROM: mem_rdata[31:16] = bytes 2k, 2k+1 for the even
			// longword half; [15:0] for the odd.  Present them on the odd
			// lanes, even lanes float high.
			complete(svc_walker, svc_card_odd ? {8'hFF, mem_rdata[15:8], 8'hFF, mem_rdata[7:0]}
			                                 : {8'hFF, mem_rdata[31:24], 8'hFF, mem_rdata[23:16]});
		else
			complete(svc_walker, mem_rdata);
	end
	S_IO8: begin
		if (io_pend[1]) begin
			io_rdata[23:16] <= io8_rdata;
			io_pend[1]      <= 1'b0;
		end
		else if (io_pend[0]) begin
			io_rdata[7:0]   <= io8_rdata;
			io_pend[0]      <= 1'b0;
		end
		else begin
			complete(svc_walker, io_rdata);
			ev_stb    <= 1;
			ev_kind   <= EV_IO8;
			ev_addr   <= {svc_addr, 2'b00};
			ev_be     <= svc_be;
			ev_write  <= svc_write;
			ev_data   <= svc_write ? svc_wdata : io_rdata;
			ev_fc     <= svc_fc;
			ev_walker <= svc_walker;
			svc       <= S_IDLE;
		end
	end
	default: svc <= S_IDLE;
	endcase
end

endmodule
