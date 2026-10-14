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
//  0 travels the loop: here one HP 46021A ITF keyboard (MAME hlebase.cpp /
//  hlekbd.cpp HLE).  The keyboard answers commands addressed to it (or to
//  address 0): IFC, EPT/ELB pass-through, auto-configure ($09-$0F: takes
//  address n-8 and passes n+1 on), POL (a $40 header and its queued key
//  bytes, poll count added to the frame), DSR, IDD (layout $DF US, $04),
//  DHR; then, unless in pass-through, returns the command frame to the MLC,
//  which raises its interrupt.  Key events arrive as HIL keycodes on
//  kbd_stb/kbd_code (bit 0 = release) into an 8-deep queue.
//
//  The RTC is rtl/msm58321.sv, set from MiSTer's RTC; beeper writes are
//  dropped (SN76494 still to do).
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

	input      [64:0] rtc_set,        // hps_io RTC (MSM6242B layout, bit 64 toggles)

	input             kbd_stb,
	input       [7:0] kbd_code,

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
wire [3:0] rtc_dout;
wire [7:0] p1_in = hil_read ? mlc_dout : latch_data[5] ? {4'h0, rtc_dout} : 8'hFF;

msm58321 rtc (
	.clk(clk),
	.reset(reset),
	.cs2(latch_data[4]),
	.read(latch_data[5]),
	.write(p2_out[2]),
	.address_write(p2_out[1]),
	.din(p1_out[3:0]),
	.dout(rtc_dout),
	.rtc_set(rtc_set)
);

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

// ---- keyboard (HP 46021A ITF, HLE) ----
reg  [7:0] kq [0:7];
reg  [2:0] kq_rd, kq_wr;
reg  [3:0] kq_cnt;
reg  [2:0] kbd_id;
reg  [3:0] poll_left;            // queued keys this poll still has to send
wire       kbd_deq = (lst == L_KEYS);
wire       kbd_enq = kbd_stb && (kq_cnt != 4'd8 || kbd_deq);
reg        kbd_passthru;

// loop transaction: frames the keyboard sends back, one per clock
localparam L_IDLE = 3'd0, L_HDR = 3'd1, L_KEYS = 3'd2, L_IDD1 = 3'd3, L_IDD2 = 3'd4, L_ECHO = 3'd5;
reg  [2:0] lst;
reg [11:0] l_frame;              // the command frame as it returns

wire [11:0] wr_frame = {w1, p1_out};
wire        wr_cmd   = wr_frame[11];
wire  [7:0] wr_data  = wr_frame[7:0];
wire        for_kbd  = wr_cmd && (wr_frame[10:8] == 3'd0 || wr_frame[10:8] == kbd_id);

// MLC receives a frame from the loop (MAME hp_hil_mlc_device::hil_write)
reg        push;
reg [11:0] push_frame;
always @(*) begin
	push = 1'b0; push_frame = 12'd0;
	case (lst)
	L_HDR:  begin push = 1'b1; push_frame = {1'b0, kbd_id, 8'h40}; end
	L_KEYS: begin push = 1'b1; push_frame = {1'b0, kbd_id, kq[kq_rd]}; end
	L_IDD1: begin push = 1'b1; push_frame = {1'b0, kbd_id, 8'hDF}; end
	L_IDD2: begin push = 1'b1; push_frame = {1'b0, kbd_id, 8'h04}; end
	L_ECHO: begin push = 1'b1; push_frame = l_frame; end
	default: ;
	endcase
end

always @(posedge clk) begin
	if (reset) begin
		f_rd <= 0; f_wr <= 0; f_cnt <= 0;
		r2 <= 0; r3 <= 0; w1 <= 0; w2 <= 0; w3 <= 0;
		kq_rd <= 0; kq_wr <= 0; kq_cnt <= 0; kbd_id <= 0; kbd_passthru <= 0;
		lst <= L_IDLE;
	end
	else begin
		// key events into the keyboard's queue (dropped when full); the
		// poll drains it one byte per clock in L_KEYS
		if (kbd_enq) begin kq[kq_wr] <= kbd_code; kq_wr <= kq_wr + 3'd1; end
		if (kbd_deq) kq_rd <= kq_rd + 3'd1;
		kq_cnt <= kq_cnt + {3'd0, kbd_enq} - {3'd0, kbd_deq};

		// frames arriving at the MLC
		if (push) begin
			if (f_cnt != 5'd16) begin
				if (!push_frame[11]) begin
					fifo[f_wr] <= push_frame; f_wr <= f_wr + 4'd1; f_cnt <= f_cnt + 5'd1;
				end
				else if (f_cnt != 0 || !w2[2]) begin              // IPF
					fifo[f_wr] <= push_frame; f_wr <= f_wr + 4'd1; f_cnt <= f_cnt + 5'd1;
					r3[0] <= 1'b1;
					w3[1] <= 1'b0;                               // APE
				end
			end
			else begin
				r2[2] <= 1'b1;                                   // FOF
				r3[0] <= 1'b1;
			end
		end

		if (lst == L_KEYS) poll_left <= poll_left - 4'd1;
		case (lst)
		L_HDR:  lst <= L_KEYS;
		L_KEYS: if (poll_left == 4'd1) lst <= L_ECHO;
		L_IDD1: lst <= L_IDD2;
		L_IDD2: lst <= L_ECHO;
		L_ECHO: lst <= L_IDLE;
		default: ;
		endcase

		if (mlc_wr) begin
			case (mlc_reg)
			2'd0: begin
				// a frame goes round the loop; the FIFO starts empty
				f_rd <= 0; f_wr <= 0; f_cnt <= 0;
				l_frame <= wr_frame;
				lst     <= kbd_passthru ? L_IDLE : L_ECHO;
				if (for_kbd) begin
					casez (wr_data)
					8'h00: ;                                         // IFC
					8'h01: begin kbd_passthru <= 1'b1; lst <= L_IDLE; end   // EPT
					8'h02: begin kbd_passthru <= 1'b0; lst <= L_ECHO; end   // ELB
					8'h03: lst <= L_IDD1;                            // IDD
					8'h04: kbd_id <= 3'd0;                           // DSR
					8'b0000_1???: if (wr_data != 8'h08) begin        // ACF
						kbd_id  <= wr_data[2:0];                     // n - 8
						l_frame <= {wr_frame[11:3], 3'd0} + {4'd0, wr_data} - 12'd7;
					end
					8'b0001_????: begin                              // POL
						// the reply covers the keys queued now; later ones
						// wait for the next poll
						l_frame   <= wr_frame + (kq_cnt != 0 ? {8'd0, kq_cnt} + 12'd1 : 12'd0);
						poll_left <= kq_cnt;
						if (kq_cnt != 0) lst <= L_HDR;
					end
					8'hFE: begin                                     // DHR
						kbd_passthru <= 1'b0;
						lst <= L_IDLE;                               // passes on: nobody echoes
					end
					default: ;
					endcase
				end
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
