//============================================================================
//  mb87030 — Fujitsu MB87030 SPC (SCSI Protocol Controller), initiator role.
//  Reference: MAME machine/mb87030.cpp (Sven Schnelle), as used by the
//  HP 98265A SCSI card (bus/hp_dio/hp98265a.cpp), where the SPC is always
//  the initiator at ID 7.  See docs/reference/scsi.md.
//
//  Register map (rs, MAME order):     read              write
//    0  BDID   1 << id                id (bits 2:0)
//    1  SCTL   control                control
//    2  SCMD   command                command (starts it)
//    3  TMOD   transfer mode (stored, sync transfers are not modelled)
//    4  INTS   interrupt status       write 1 to clear
//    5  PSNS / SDGC  bus phase sense  diagnostic control
//    6  SSTS   SPC status             --
//    7  SERR   0 (no parity / sync errors are modelled)
//    8  PCTL   phase control (7 bus-free IE, 2:0 expected phase)
//    9  MBC    0
//   10  DREG   data FIFO (8 bytes)
//   11  TEMP   temporary register (selection IDs, manual handshake byte)
//   12-14 TCH/TCM/TCL  24-bit transfer counter (also the selection timeout)
//   15  EXBF   stored
//
//  SCMD commands (bits 7:5): 0 bus release, 1 select (arbitration first when
//  SCTL bit 4 is set), 2 reset ATN, 3 set ATN (latched for the selection
//  when idle), 4 transfer (bit 2 = program transfer, else DMA; bit 0 =
//  padding/terminal mode), 5 transfer pause (no-op, as in MAME), 6 reset
//  ACK/REQ, 7 set ACK/REQ (manual handshake through TEMP).  Bit 4 drives
//  SCSI RST and aborts everything.
//
//  INTS: 0x80 selected / 0x40 reselected (target mode, never set), 0x20
//  disconnected, 0x10 command complete, 0x08 service required (phase
//  mismatch during a transfer), 0x04 time-out (selection), 0x02 SPC hard
//  error and 0x01 reset condition (never set, as in MAME).  irq =
//  SCTL bit 0 && INTS != 0.
//
//  Timing: MAME's chip-clock delays (8 MHz clocks) become cycle counters of
//  N * ceil(CLK_HZ / 8 MHz); the selection time-out runs on an 8 MHz tick
//  derived from CLK_HZ: ((TC & 0xFFFF00) + 15) * 2 chip clocks.  A bus
//  that stays free for 10 ms while connected disconnects the SPC (MAME's
//  bus-free timer).
//
//  Ports:
//    cs/we/rs/din/dout  one register access per cs pulse; dout is
//           combinational, side effects (DREG pop) on the clock edge.
//    dreq   high while the SPC wants a byte moved.  It already accounts for
//           a dack_rd / dack_wr in the same cycle, so a DMA engine may
//           sample it in the cycle of its own acknowledge.
//    dack_rd / dack_dout  one byte out of the FIFO per pulse (data valid in
//           the same cycle);  dack_wr / dack_din  one byte into the FIFO.
//    ext_ctrl_wr / ext_ctrl  the card's direct control of the SPC's own SCSI
//           lines (98265A register 2), all 9 lines replaced, MAME S_* order:
//           [0] I/O  [1] C/D  [2] MSG  [3] BSY  [4] SEL  [5] REQ  [6] ACK
//           [7] ATN  [8] RST
//    scsi_*_o  this device's asserted lines (active high);  scsi_*_i the
//           resolved bus (the OR of every device, including this one).
//============================================================================

module mb87030
#(
	parameter CLK_HZ = 33_000_000
)
(
	input            clk,
	input            reset,

	input            cs,
	input            we,
	input      [3:0] rs,
	input      [7:0] din,
	output reg [7:0] dout,
	output           irq,

	output           dreq,
	input            dack_rd,
	output     [7:0] dack_dout,
	input            dack_wr,
	input      [7:0] dack_din,

	input            ext_ctrl_wr,
	input      [8:0] ext_ctrl,

	output     [7:0] scsi_data_o,
	output           scsi_bsy_o, scsi_sel_o, scsi_atn_o, scsi_ack_o, scsi_rst_o,
	output           scsi_req_o, scsi_msg_o, scsi_cd_o, scsi_io_o,
	input      [7:0] scsi_data_i,
	input            scsi_bsy_i, scsi_sel_i, scsi_atn_i, scsi_ack_i, scsi_rst_i,
	input            scsi_req_i, scsi_msg_i, scsi_cd_i, scsi_io_i
);

// ---- control line bits (MAME nscsi S_* order) ----
localparam [8:0] L_IO  = 9'h001, L_CD  = 9'h002, L_MSG = 9'h004, L_BSY = 9'h008,
                 L_SEL = 9'h010, L_REQ = 9'h020, L_ACK = 9'h040, L_ATN = 9'h080,
                 L_RST = 9'h100, L_ALL = 9'h1FF;

// ---- delays: MAME chip clocks -> cycles ----
localparam integer T1      = (CLK_HZ + 7_999_999) / 8_000_000;
/* verilator lint_off WIDTHTRUNC */
localparam [9:0]   D1      = T1;
localparam [9:0]   D2      = 2 * T1;
localparam [9:0]   D5      = 5 * T1;
localparam [9:0]   D10     = 10 * T1;
localparam [9:0]   D32     = 32 * T1;
localparam integer BF_CLKS = CLK_HZ / 100;              // 10 ms bus-free timer
localparam integer BFW     = $clog2(BF_CLKS + 1);
localparam [BFW-1:0] BF_LAST = BF_CLKS - 1;
/* verilator lint_on WIDTHTRUNC */

// ---- states (MAME's State enum) ----
localparam [4:0] S_IDLE      = 5'd0,  S_WAIT      = 5'd1,
                 S_ARB_FREE  = 5'd2,  S_ARB_BSY   = 5'd3,
                 S_ARB_WAIT  = 5'd4,  S_ARB_SEL   = 5'd5,
                 S_SEL_FREE  = 5'd6,  S_SEL_ID    = 5'd7,
                 S_SEL_SEL   = 5'd8,  S_SEL_WBSY  = 5'd9,
                 S_SELECTION = 5'd10, S_X_WREQ    = 5'd11,
                 S_X_SEND    = 5'd12, S_X_RECV    = 5'd13,
                 S_X_ACK     = 5'd14, S_X_WNREQ   = 5'd15,
                 S_X_NACK    = 5'd16, S_X_FIFO    = 5'd17;

// ---- registers ----
reg  [2:0] bdid;
reg  [7:0] sctl, scmd, tmod, ints, sdgc, pctl, dreg, temp, exbf;
reg [23:0] tc;
reg        init_conn, spc_busy, xfer_ip;     // SSTS 7, 5, 4
reg        send_atn;                         // ATN during the next selection
reg        dma_xfer;                         // last transfer command was DMA
reg        dreq_en, dreq_in;                 // DMA wanted, direction
reg        inflight;                         // data-out byte on the bus, not yet ACKed
reg  [8:0] bctl;                             // our lines on the bus
reg  [8:0] dctl;                             // our lines in diagnostic mode (not on the bus)
reg  [7:0] odata;                            // our data lines
reg  [4:0] state, dstate;
reg  [9:0] dly;
reg        to_run;
reg [25:0] to_cnt;
reg        bf_q;                             // bus-free interrupt condition, last cycle
reg [BFW-1:0] bf_cnt;

// ---- 8-byte data FIFO ----
reg  [7:0] fifo [0:7];
reg  [2:0] rp, wp;
reg  [3:0] fcnt;
wire [7:0] head  = fifo[rp];
wire       fempty = (fcnt == 4'd0);
wire       ffull  = (fcnt == 4'd8);

// ---- 8 MHz chip-clock tick for the selection time-out ----
reg [31:0] tacc;
wire [32:0] tsum  = {1'b0, tacc} + 33'd8_000_000;
wire        tick  = (tsum >= CLK_HZ);
wire [31:0] tdiff = tsum[31:0] - CLK_HZ;
always @(posedge clk)
	tacc <= reset ? 32'd0 : tick ? tdiff : tsum[31:0];

// ---- the bus as this device sees it ----
wire [8:0] bus_ctl = {scsi_rst_i, scsi_atn_i, scsi_ack_i, scsi_req_i, scsi_sel_i,
                      scsi_bsy_i, scsi_msg_i, scsi_cd_i, scsi_io_i};
wire       diag    = sctl[5];
// diagnostic mode: SDGC bits stand in for the target's lines (MAME scsi_get_ctrl)
wire [8:0] cv = diag ? {1'b0, dctl[7], dctl[6] | sdgc[6], dctl[5] | sdgc[7], dctl[4],
                        dctl[3] | sdgc[3], dctl[2] | sdgc[2], dctl[1] | sdgc[1], dctl[0] | sdgc[0]}
                     : bus_ctl;
wire [7:0] bus_data = scsi_data_i;
wire [2:0] phase    = cv[2:0];               // {MSG, C/D, I/O}

assign {scsi_rst_o, scsi_atn_o, scsi_ack_o, scsi_req_o, scsi_sel_o,
        scsi_bsy_o, scsi_msg_o, scsi_cd_o, scsi_io_o} = bctl;
// an initiator never drives the data lines while the target asserts I/O
assign scsi_data_o = (scsi_io_i && !bctl[0]) ? 8'h00 : odata;

assign irq = sctl[0] && (ints != 8'h00);

// selection time-out in chip clocks: ((TC & ~0xFF) + 15) * 2
// (SIM_FAST_SELTO, the full-system sim only: 1/64 of that, so the boot
// ROM's scan past empty IDs takes ~1.3M clocks instead of ~83M)
`ifdef SIM_FAST_SELTO
wire [25:0] sel_to = {7'd0, tc[23:8], 3'b001};
`else
wire [25:0] sel_to = {1'b0, tc[23:8], 8'h0F, 1'b0};
`endif

// DMA request; corrected for an acknowledge in this very cycle
wire [4:0] out_pend = {1'b0, fcnt} + {4'd0, inflight} + {4'd0, dack_wr};
assign dreq = dreq_en && (dreq_in ? (fcnt > {3'd0, dack_rd})
                                  : (({1'b0, fcnt} + {4'd0, dack_wr}) < 5'd8) && ({19'd0, out_pend} < tc));
assign dack_dout = fempty ? dreg : head;

wire [7:0] ssts = {init_conn, 1'b0, spc_busy, xfer_ip, bus_ctl[8], tc == 24'd0,
                   ffull && !(dma_xfer && xfer_ip), fempty};
wire [7:0] psns = {cv[5], cv[6], cv[7], cv[4], cv[3], cv[2], cv[1], cv[0]};

// ---- register read (combinational) ----
always @(*) begin
	case (rs)
	4'd0:  dout = 8'd1 << bdid;
	4'd1:  dout = sctl;
	4'd2:  dout = scmd;
	4'd3:  dout = tmod;
	4'd4:  dout = ints;
	4'd5:  dout = psns;
	4'd6:  dout = ssts;
	4'd7:  dout = 8'h00;                     // SERR
	4'd8:  dout = pctl;
	4'd9:  dout = 8'h00;                     // MBC
	4'd10: dout = fempty ? dreg : head;
	4'd11: dout = temp;
	4'd12: dout = tc[23:16];
	4'd13: dout = tc[15:8];
	4'd14: dout = tc[7:0];
	default: dout = exbf;
	endcase
end

//----------------------------------------------------------------------------
// next state
//----------------------------------------------------------------------------
reg  [2:0] bdid_n;
reg  [7:0] sctl_n, scmd_n, tmod_n, ints_n, sdgc_n, pctl_n, dreg_n, temp_n, exbf_n;
reg [23:0] tc_n;
reg        init_conn_n, spc_busy_n, xfer_ip_n, send_atn_n, dma_xfer_n;
reg        dreq_en_n, dreq_in_n, inflight_n;
reg  [8:0] bctl_n, dctl_n;
reg  [7:0] odata_n;
reg  [4:0] state_n, dstate_n;
reg  [9:0] dly_n;
reg        to_run_n;
reg [25:0] to_cnt_n;
reg        bf_q_n;
reg [BFW-1:0] bf_cnt_n;
reg        push, pop, fclr;
reg  [7:0] push_d;
reg        bf_cond, term;
reg [23:0] tc_dec;

// scsi_set_ctrl(): diagnostic mode keeps the lines off the bus
task automatic set_ctrl(input [8:0] v, input [8:0] m);
	if (diag) dctl_n = (dctl_n & ~m) | (v & m);
	else      bctl_n = (bctl_n & ~m) | (v & m);
endtask

// update_state(new, delay, timeout)
task automatic go(input [4:0] ns, input [9:0] d, input t);
	if (d != 10'd0) begin
		state_n  = S_WAIT;
		dstate_n = ns;
		dly_n    = d - 10'd1;
	end
	else
		state_n = ns;
	to_run_n = t;
	if (t) to_cnt_n = sel_to;
endtask

task automatic command_complete;
	dreq_en_n  = 1'b0;
	ints_n     = ints_n | 8'h10;
	spc_busy_n = 1'b0;
	xfer_ip_n  = 1'b0;
	go(S_IDLE, 10'd0, 1'b0);
endtask

task automatic disconnect;
	dreq_en_n   = 1'b0;
	init_conn_n = 1'b0;
	spc_busy_n  = 1'b0;
	xfer_ip_n   = 1'b0;
	ints_n      = 8'h20;
	go(S_IDLE, 10'd0, 1'b0);
endtask

always @(*) begin
	bdid_n = bdid; sctl_n = sctl; scmd_n = scmd; tmod_n = tmod; ints_n = ints;
	sdgc_n = sdgc; pctl_n = pctl; dreg_n = dreg; temp_n = temp; exbf_n = exbf;
	tc_n = tc;
	init_conn_n = init_conn; spc_busy_n = spc_busy; xfer_ip_n = xfer_ip;
	send_atn_n = send_atn; dma_xfer_n = dma_xfer;
	dreq_en_n = dreq_en; dreq_in_n = dreq_in; inflight_n = inflight;
	bctl_n = bctl; dctl_n = dctl; odata_n = odata;
	state_n = state; dstate_n = dstate; dly_n = dly;
	to_run_n = to_run; to_cnt_n = to_cnt;
	bf_cnt_n = bf_cnt;

	// TEMP follows the data bus while the target offers a byte in an input
	// phase (initiator, I/O and REQ up, ACK not yet): NetBSD's mb89352 driver
	// reads STATUS and MESSAGE IN bytes from TEMP before it sets ACK.  (MAME
	// only latches TEMP on SET ACK, which leaves such reads one byte behind.)
	if (init_conn && cv[0] && cv[5] && !cv[6]) temp_n = bus_data;
	push = 1'b0; push_d = 8'h00; pop = 1'b0; fclr = 1'b0;
	term = 1'b0; tc_dec = tc;

	// ---- selection time-out timer ----
	if (to_run && to_cnt != 26'd0 && tick) to_cnt_n = to_cnt - 26'd1;
	if (to_run && to_cnt == 26'd0) to_run_n = 1'b0;     // fires this cycle

	// Idle with PCTL bus-free IE: a free bus reports the disconnect (once)
	bf_cond = (state == S_IDLE) && pctl[7] && (cv == 9'd0);
	bf_q_n  = bf_cond;

	// Reset & disable releases RST.  HP-UX 9 ends its bus reset this way
	// (SCMD = RST, SCTL = C0, SCMD = 0); MAME leaves RST on the bus until the
	// next SCMD write with SCTL[7] clear.  The registers keep their values:
	// the boot ROM's register test writes SCMD with SCTL[7] set and reads it
	// back.
	if (sctl[7]) set_ctrl(9'd0, L_RST);

	// ---- state machine (MAME step()) ----
	if (sctl[7] && state != S_IDLE) begin
		// reset & disable: drop everything
		set_ctrl(9'd0, L_ALL);
		odata_n    = 8'h00;
		spc_busy_n = 1'b0;
		fclr       = 1'b1;
		go(S_IDLE, 10'd0, 1'b0);
	end
	else case (state)
	S_IDLE:
		if (bf_cond && !bf_q) disconnect();

	S_WAIT:
		if (dly == 10'd0) state_n = dstate;
		else dly_n = dly - 10'd1;

	S_ARB_FREE:
		if (!cv[3] && !cv[4]) go(S_ARB_BSY, D1, 1'b0);

	S_ARB_BSY: begin
		set_ctrl(L_BSY, L_BSY);
		odata_n = 8'd1 << bdid;
		go(S_ARB_WAIT, D32, 1'b0);
	end

	S_ARB_WAIT:
		// a higher ID on the bus wins
		if ((bus_data & ~((8'd2 << bdid) - 8'd1)) != 8'h00) begin
			set_ctrl(9'd0, L_BSY);
			odata_n    = 8'h00;
			spc_busy_n = 1'b0;
			go(S_IDLE, 10'd0, 1'b0);
		end
		else go(S_ARB_SEL, D1, 1'b0);

	S_ARB_SEL: begin
		set_ctrl(L_SEL, L_SEL);
		go(S_SEL_ID, D10, 1'b0);
	end

	S_SEL_FREE:
		if (!cv[3] && !cv[4]) go(S_SEL_ID, D10, 1'b0);

	S_SEL_ID: begin
		init_conn_n = 1'b1;
		odata_n     = temp;                   // initiator + target ID bits
		go(S_SEL_SEL, D10, 1'b0);
	end

	S_SEL_SEL: begin
		// assert SEL (and ATN), release BSY from arbitration
		set_ctrl(L_SEL | (send_atn ? L_ATN : 9'd0), L_ATN | L_SEL | L_BSY);
		go(S_SEL_WBSY, 10'd0, 1'b1);
	end

	S_SEL_WBSY:
		if ((to_run && to_cnt == 26'd0) || ints[2]) begin
			tc_n   = 24'd0;
			ints_n = 8'h04;
		end
		else if ((cv & (L_REQ | L_BSY | L_MSG | L_CD | L_IO)) == L_BSY)
			go(S_SELECTION, D1, 1'b0);

	S_SELECTION:
		if (cv[4]) begin
			set_ctrl(9'd0, L_SEL);
			odata_n = 8'h00;                  // release the ID bits with SEL
			command_complete();
		end

	S_X_WREQ:
		if (cv[5]) begin
			if (phase != pctl[2:0]) begin
				// phase mismatch: service required
				dreq_en_n  = 1'b0;
				ints_n     = ints_n | 8'h08;
				spc_busy_n = 1'b0;
				odata_n    = 8'h00;
				go(S_IDLE, 10'd0, 1'b0);
			end
			else if (tc == 24'd0 && !scmd[0]) begin
				// zero-length transfer: only checks the phase
				odata_n = 8'h00;
				command_complete();
			end
			else begin
				go(cv[0] ? S_X_RECV : S_X_SEND, 10'd0, 1'b0);
				if (dma_xfer && tc != 24'd0) begin
					dreq_en_n = 1'b1;
					dreq_in_n = cv[0];
				end
			end
		end

	S_X_RECV:
		if (tc == 24'd0 && scmd[0])
			go(S_X_ACK, D2, 1'b0);
		else if (tc != 24'd0 && !ffull) begin
			push   = 1'b1;
			push_d = bus_data;
			go(S_X_ACK, D10, 1'b0);
		end

	S_X_SEND:
		if (tc != 24'd0 && !fempty) begin
			odata_n    = head;
			pop        = 1'b1;
			inflight_n = 1'b1;
			go(S_X_ACK, D2, 1'b0);
		end
		else if (tc == 24'd0 && scmd[0]) begin
			odata_n = temp;
			go(S_X_ACK, D2, 1'b0);
		end

	S_X_ACK: begin
		if (!scmd[0] && !cv[0]) temp_n = bus_data;
		set_ctrl(L_ACK, L_ACK);
		go(S_X_WNREQ, D1, 1'b0);
	end

	S_X_WNREQ:
		if (!cv[5]) go(S_X_NACK, D1, 1'b0);

	S_X_NACK: begin
		term       = (tc == 24'd0) && scmd[0];
		tc_dec     = term ? tc : tc - 24'd1;
		tc_n       = tc_dec;
		inflight_n = 1'b0;
		go((tc_dec != 24'd0) ? S_X_WREQ : S_X_FIFO, D1, 1'b0);
		if (tc_dec == 24'd0 && phase == 3'b110 && send_atn)
			set_ctrl(9'd0, L_ATN | L_ACK);   // last MESSAGE OUT byte: drop ATN
		else if (tc_dec != 24'd0 || phase != 3'b111)
			set_ctrl(9'd0, L_ACK);           // ACK stays on the last MESSAGE IN byte
	end

	S_X_FIFO:
		if (fempty) begin
			odata_n = 8'h00;
			command_complete();
		end

	default: go(S_IDLE, 10'd0, 1'b0);
	endcase

	// ---- MAME's bus-free timer: 10 ms of free bus while connected ----
	if (init_conn && !cv[3] && !cv[4]) begin
		if (bf_cnt == BF_LAST) begin
			disconnect();
			set_ctrl(9'd0, L_ALL);
			bf_cnt_n = '0;
		end
		else bf_cnt_n = bf_cnt + 1'd1;
	end
	else bf_cnt_n = '0;

	// ---- host register access (wins over the state machine) ----
	if (cs && we) begin
		case (rs)
		4'd0: bdid_n = din[2:0];
		4'd1: sctl_n = din;
		4'd2: begin
			scmd_n = din;
			if (!sctl[7]) set_ctrl(din[4] ? L_RST : 9'd0, L_RST);
			if (din[4]) begin
				// RST out: abort
				dreq_en_n   = 1'b0;
				fclr        = 1'b1;
				odata_n     = 8'h00;
				init_conn_n = 1'b0;
				spc_busy_n  = 1'b0;
				xfer_ip_n   = 1'b0;
				go(S_IDLE, 10'd0, 1'b0);
			end
			else case (din[7:5])
			3'd0: begin                                   // bus release
				send_atn_n = 1'b0;
				if (state == S_SEL_FREE) begin
					init_conn_n = 1'b0;
					spc_busy_n  = 1'b0;
					xfer_ip_n   = 1'b0;
					go(S_IDLE, 10'd0, 1'b0);
				end
			end
			3'd1: begin                                   // select
				spc_busy_n = 1'b1;
				go(sctl[4] ? S_ARB_FREE : S_SEL_FREE, D10, 1'b0);
			end
			3'd2: begin                                   // reset ATN
				send_atn_n = 1'b0;
				set_ctrl(9'd0, L_ATN);
			end
			3'd3:                                         // set ATN
				if (state == S_IDLE) send_atn_n = 1'b1;
				else set_ctrl(L_ATN, L_ATN);
			3'd4:                                         // transfer
				if (init_conn) begin
					dma_xfer_n = !din[2];
					dreq_en_n  = 1'b0;
					spc_busy_n = 1'b1;
					xfer_ip_n  = 1'b1;
					go(S_X_WREQ, D5, 1'b0);
				end
			3'd5: ;                                       // transfer pause
			3'd6:                                         // reset ACK/REQ
				if (init_conn) set_ctrl(9'd0, L_ACK);
			default:                                      // set ACK/REQ
				if (init_conn) begin
					if (bus_ctl[0]) temp_n  = bus_data;
					else            odata_n = temp;
					set_ctrl(L_ACK, L_ACK);
				end
			endcase
		end
		4'd3: tmod_n = din;
		4'd4: begin
			if (state == S_SEL_WBSY && (ints & din & 8'h04) != 8'h00) begin
				if (tc == 24'd0) begin
					// terminate the selection
					init_conn_n = 1'b0;
					spc_busy_n  = 1'b0;
					set_ctrl(9'd0, L_ALL);
					odata_n     = 8'h00;
					go(S_IDLE, 10'd0, 1'b0);
				end
				else go(S_SEL_ID, D1, 1'b0);          // retry with the new TC
			end
			ints_n = ints_n & ~(din & ints);          // bits set this cycle survive
		end
		4'd5: sdgc_n = din & 8'hDF;                   // no XFER_ENABLE on the MB87030
		4'd8: pctl_n = din;
		4'd10: begin
			dreg_n = din;
			if (!push && !ffull) begin push = 1'b1; push_d = din; end
		end
		4'd11: temp_n = din;
		4'd12: tc_n[23:16] = din;
		4'd13: tc_n[15:8]  = din;
		4'd14: tc_n[7:0]   = din;
		4'd15: exbf_n = din;
		default: ;
		endcase
	end
	else if (cs && rs == 4'd10 && !fempty) begin
		dreg_n = head;
		pop    = 1'b1;
	end

	// ---- DMA ----
	if (dack_wr) begin
		dreg_n = dack_din;
		if (!push && !ffull) begin push = 1'b1; push_d = dack_din; end
	end
	if (dack_rd && !fempty) begin
		dreg_n = head;
		pop    = 1'b1;
	end

	// ---- card register 2: direct line control (bypasses diagnostic mode) ----
	if (ext_ctrl_wr) bctl_n = ext_ctrl;
end

//----------------------------------------------------------------------------
// registers
//----------------------------------------------------------------------------
always @(posedge clk) begin
	if (reset) begin
		bdid <= 3'd0; sctl <= 8'h80; scmd <= 8'h00; tmod <= 8'h00; ints <= 8'h00;
		sdgc <= 8'h00; pctl <= 8'h00; dreg <= 8'h00; temp <= 8'h00; exbf <= 8'h00;
		tc <= 24'd0;
		init_conn <= 1'b0; spc_busy <= 1'b0; xfer_ip <= 1'b0;
		send_atn <= 1'b0; dma_xfer <= 1'b0;
		dreq_en <= 1'b0; dreq_in <= 1'b0; inflight <= 1'b0;
		bctl <= 9'd0; dctl <= 9'd0; odata <= 8'h00;
		state <= S_IDLE; dstate <= S_IDLE; dly <= 10'd0;
		to_run <= 1'b0; to_cnt <= 26'd0;
		bf_q <= 1'b0; bf_cnt <= '0;
		rp <= 3'd0; wp <= 3'd0; fcnt <= 4'd0;
	end
	else begin
		bdid <= bdid_n; sctl <= sctl_n; scmd <= scmd_n; tmod <= tmod_n; ints <= ints_n;
		sdgc <= sdgc_n; pctl <= pctl_n; dreg <= dreg_n; temp <= temp_n; exbf <= exbf_n;
		tc <= tc_n;
		init_conn <= init_conn_n; spc_busy <= spc_busy_n; xfer_ip <= xfer_ip_n;
		send_atn <= send_atn_n; dma_xfer <= dma_xfer_n;
		dreq_en <= dreq_en_n; dreq_in <= dreq_in_n; inflight <= inflight_n;
		bctl <= bctl_n; dctl <= dctl_n; odata <= odata_n;
		state <= state_n; dstate <= dstate_n; dly <= dly_n;
		to_run <= to_run_n; to_cnt <= to_cnt_n;
		bf_q <= bf_q_n; bf_cnt <= bf_cnt_n;

		if (fclr) begin
			rp <= 3'd0; wp <= 3'd0; fcnt <= 4'd0;
		end
		else begin
			if (push) begin
				fifo[wp] <= push_d;
				wp <= wp + 3'd1;
			end
			if (pop) rp <= rp + 3'd1;
			fcnt <= fcnt + {3'd0, push} - {3'd0, pop};
		end
	end
end

endmodule
