//============================================================================
//  hil_card — the HP 300 "human interface": 8042 HIL controller with its
//  1820-4784 firmware, HP-HIL link controller (MLC), RTC and beeper.
//  Wiring from MAME bus/hp_dio/human_interface.cpp and bus/hp_hil/hp_hil.cpp.
//
//  Host: 8042 data at $420001 (A0 = 0), command/status at $420003 (A0 = 1),
//  mirrored over $42xxxx (the boot ROM uses $428001/3).
//
//  8042 ports:
//    P1      shared data bus to the MLC, the RTC and the SN76494
//    P2.0    !HIL_CS       P2.1  !HIL_WE / RTC address write
//    P2.2    !HIL_OE / RTC write                P2.3  latch enable (rising)
//    P2.4    OBF -> IRQ 1 (EN FLAGS)            P2.6  low = keyboard NMI (IRQ 7)
//    P2.7    low = SN76494 write
//    latch   7:6 MLC register, 5 RTC read, 4 RTC CS2
//    T0      !MLC interrupt          T1 = 1        P2 input = $DF
//
//  MLC: 16-deep FIFO of 12-bit frames, R2 errors, R3 status (clear on read),
//  W1 frame address bits, W2 (IPF), W3 (APE).  A frame written to register
//  0 travels the loop; with no devices attached (this revision) nothing
//  answers, as MAME's MLC behaves with empty slots.
//
//  The RTC (MSM58321) and the beeper are stubs: RTC reads return 0, beeper
//  writes are dropped.
//============================================================================

module hil_card
#(
	parameter MC_DIV = 99            // clk / 8042 machine-cycle rate (33 MHz / (5 MHz / 15))
)
(
	input             clk,
	input             reset,          // includes the DIO reset

	input             rom_wr,
	input      [10:0] rom_addr,
	input       [7:0] rom_data,

	input             host_cs,
	input             host_we,
	input             host_a0,
	input       [7:0] host_din,
	output      [7:0] host_dout,

	output            irq1,
	output            nmi,            // keyboard reset NMI (IRQ 7) / KBDNMIST

	output     [10:0] dbg_pc,
	output            dbg_dispatch
);

// ---- 8042 machine-cycle tick ----
reg [$clog2(MC_DIV)-1:0] mc_div;
wire mc_tick = (mc_div == MC_DIV - 1);
always @(posedge clk) mc_div <= (reset || mc_tick) ? '0 : mc_div + 1'd1;

wire [7:0] p1_out, p2_out;
wire       p1_rd;
reg  [7:0] latch_data;
wire       mlc_int;
wire       hil_read = (p2_out[0] | p2_out[2]) == 1'b0;
wire [7:0] mlc_dout;
wire [7:0] p1_in = hil_read ? mlc_dout : latch_data[5] ? 8'h00 /* RTC stub */ : 8'hFF;

upi41 cpu (
	.clk(clk),
	.reset(reset),
	.mc_tick(mc_tick),
	.rom_wr(rom_wr),
	.rom_addr(rom_addr),
	.rom_data(rom_data),
	.host_cs(host_cs),
	.host_we(host_we),
	.host_a0(host_a0),
	.host_din(host_din),
	.host_dout(host_dout),
	.p1_in(p1_in),
	.p1_out(p1_out),
	.p2_in(8'hDF),
	.p2_out(p2_out),
	.t0(!mlc_int),
	.t1(1'b1),
	.p1_rd(p1_rd),
	.dbg_pc(dbg_pc),
	.dbg_dispatch(dbg_dispatch)
);

assign irq1 = p2_out[4];
assign nmi  = !p2_out[6];

// ---- strobes from P2 ----
reg  [7:0] p2_q;
always @(posedge clk) p2_q <= reset ? 8'hFF : p2_out;
wire mlc_wr   = ((p2_out[0] | p2_out[1]) == 1'b0) && ((p2_q[0] | p2_q[1]) != 1'b0);
wire latch_up = p2_out[3] && !p2_q[3];

always @(posedge clk)
	if (reset) latch_data <= 8'h00;
	else if (latch_up) latch_data <= p1_out;

//----------------------------------------------------------------------------
// MLC
//----------------------------------------------------------------------------
reg [11:0] fifo [0:15];
reg  [3:0] f_rd, f_wr;
reg  [4:0] f_cnt;
reg  [7:0] r2, r3, w2, w3;
reg  [3:0] w1;
wire [1:0] mlc_reg = latch_data[7:6];

assign mlc_int  = r3[0];
assign mlc_dout = mlc_reg == 2'd0 ? (f_cnt != 0 ? fifo[f_rd][7:0] : 8'h00) :
                  mlc_reg == 2'd1 ? (f_cnt != 0 ? {4'h0, fifo[f_rd][11:8]} : 8'h00) :
                  mlc_reg == 2'd2 ? r2 : r3;

always @(posedge clk) begin
	if (reset) begin
		f_rd <= 0; f_wr <= 0; f_cnt <= 0;
		r2 <= 0; r3 <= 0; w1 <= 0; w2 <= 0; w3 <= 0;
	end
	else begin
		if (mlc_wr) begin
			case (mlc_reg)
			2'd0: begin
				// send a frame round the loop: clears the FIFO; no device
				// on the loop to answer yet
				f_rd <= 0; f_wr <= 0; f_cnt <= 0;
			end
			2'd1: w1 <= p1_out[3:0];
			2'd2: w2 <= p1_out;
			2'd3: w3 <= p1_out;
			endcase
		end
		else if (p1_rd && hil_read) begin
			case (mlc_reg)
			2'd0: if (f_cnt != 0) begin f_rd <= f_rd + 4'd1; f_cnt <= f_cnt - 5'd1; end
			2'd2: r2 <= r2 & ~8'h07;
			2'd3: r3 <= r3 & ~8'h07;
			default: ;
			endcase
		end
	end
end

endmodule
