//============================================================================
//  hp98620 — HP 98620C DMA controller (two channels), at $500000-$50020F.
//  Reference: MAME bus/hp_dio/hp98620.cpp.
//
//  Registers (16-bit, byte offset within the block):
//    legacy, channel n at +8n:
//      +0  write: address high          read: clears armed + interrupt
//      +2  address low
//      +4  transfer count (count + 1 units)
//      +6  write: control, arms the channel    read: status (1 armed, 2 int)
//    +$10/+$12  ID "20C0" ($3230, $4330)        +$14 general control
//                                               (bit 4/5: disarm channel 0/1)
//    98620C ("1TQ4") set, channel n at +$100(n+1):
//      +0/+2 address high/low  +4/+6 count high/low
//      +8 control (bit 15 START arms)   +$A status
//  Control: 0 IE, 1 word, 2 out (memory -> device), 3 priority (ignored),
//  6:4 interrupt level - 3; 98620C bit 8 longword.
//
//  Like MAME, every move is one byte: memory byte <-> the device's DMA
//  acknowledge; a unit is 1, 2 or 4 bytes (byte / word / longword) and the
//  count runs in units.  At the end of the count the channel disarms and,
//  if IE, raises its interrupt at its level.  Channel 0 goes first.
//
//  Memory side: one byte per request through the system bus (the parent
//  turns it into a byte-lane beat); a bus error stops the channel.
//  Device side: dack_rd / dack_wr pulse once per byte, dack_rdata is
//  sampled in the same cycle as dack_rd.
//============================================================================

module hp98620
(
	input             clk,
	input             reset,

	input             reg_cs,
	input             reg_we,
	input       [9:1] reg_word,
	input       [1:0] reg_be,
	input      [15:0] reg_din,
	output reg [15:0] reg_dout,

	input       [1:0] dmar,

	output reg        dack_rd,
	output reg        dack_wr,
	output reg        dack_ch,
	output reg  [7:0] dack_wdata,
	input       [7:0] dack_rdata,

	output reg        mreq,
	output reg        mwe,
	output reg [31:0] maddr,
	output reg  [7:0] mwdata,
	input             mack,
	input      [31:0] mrdata,        // the whole longword; the byte lane is picked here
	input             merr,

	output reg  [7:1] irq_lvl
);

reg [31:0] addr  [0:1];
reg [31:0] tc    [0:1];
reg [15:0] ctrl  [0:1];
reg  [1:0] armed, irq;
reg  [1:0] sub   [0:1];             // bytes left in the current unit - 1

wire [9:0] off = {reg_word, 1'b0};

function [15:0] merge16;
	input [15:0] old, nw;
	input  [1:0] be;
	merge16 = {be[1] ? nw[15:8] : old[15:8], be[0] ? nw[7:0] : old[7:0]};
endfunction

// bytes per unit - 1; like MAME, bit 8 (longword) counts on either set
function [1:0] unit_bytes_m1;
	input [15:0] c;
	unit_bytes_m1 = c[8] ? 2'd3 : c[1] ? 2'd1 : 2'd0;
endfunction

always @(*) begin
	case (off)
	10'h000, 10'h008: reg_dout = 16'h0000;
	10'h004: reg_dout = tc[0][15:0];
	10'h00C: reg_dout = tc[1][15:0];
	10'h006: reg_dout = {14'd0, irq[0], armed[0]};
	10'h00E: reg_dout = {14'd0, irq[1], armed[1]};
	10'h010: reg_dout = 16'h3230;
	10'h012: reg_dout = 16'h4330;
	10'h100: reg_dout = addr[0][31:16];
	10'h102: reg_dout = addr[0][15:0];
	10'h104: reg_dout = tc[0][31:16];
	10'h106: reg_dout = tc[0][15:0];
	10'h108: reg_dout = ctrl[0];
	10'h10A: reg_dout = {14'd0, irq[0], armed[0]};
	10'h200: reg_dout = addr[1][31:16];
	10'h202: reg_dout = addr[1][15:0];
	10'h204: reg_dout = tc[1][31:16];
	10'h206: reg_dout = tc[1][15:0];
	10'h208: reg_dout = ctrl[1];
	10'h20A: reg_dout = {14'd0, irq[1], armed[1]};
	default: reg_dout = 16'h0000;
	endcase
end

always @(*) begin
	irq_lvl = 7'd0;
	if (irq[0] && ctrl[0][0]) irq_lvl[3'd3 + ctrl[0][6:4]] = 1'b1;
	if (irq[1] && ctrl[1][0]) irq_lvl[3'd3 + ctrl[1][6:4]] = 1'b1;
end

//----------------------------------------------------------------------------
// Transfer engine: pick a channel, move one byte, account for it
//----------------------------------------------------------------------------
localparam X_IDLE = 2'd0, X_MEM = 2'd1, X_DEV = 2'd2;
reg  [1:0] xs;
reg        ch;                      // channel being served
wire       want0 = armed[0] && dmar[0];
wire       want1 = armed[1] && dmar[1];
wire [7:0] mbyte = mrdata[(2'd3 - maddr[1:0]) * 8 +: 8];

task automatic arm;
	input       n;
	input [15:0] d;
	begin
		ctrl[n]  <= d & 16'h7FFF;
		armed[n] <= 1'b1;
		irq[n]   <= 1'b0;
		sub[n]   <= unit_bytes_m1(d);
	end
endtask

// after one byte of channel n has moved
task automatic count;
	input n;
	begin
		addr[n] <= addr[n] + 32'd1;
		if (sub[n] == 2'd0) begin
			// the count runs down past zero: software checks it ends at -1
			tc[n] <= tc[n] - 32'd1;
			if (tc[n] == 32'd0) begin
				armed[n] <= 1'b0;
				if (ctrl[n][0]) irq[n] <= 1'b1;
			end
			else
				sub[n] <= unit_bytes_m1(ctrl[n]);
		end
		else sub[n] <= sub[n] - 2'd1;
	end
endtask

always @(posedge clk) begin
	dack_rd <= 1'b0;
	dack_wr <= 1'b0;
	if (reset) begin
		armed <= 0; irq <= 0; sub[0] <= 0; sub[1] <= 0; xs <= X_IDLE; mreq <= 0;
		ctrl[0] <= 0; ctrl[1] <= 0; tc[0] <= 0; tc[1] <= 0; addr[0] <= 0; addr[1] <= 0;
	end
	else begin
		// ---- register access ----
		if (reg_cs && !reg_we) begin
			if (off == 10'h000) begin irq[0] <= 1'b0; armed[0] <= 1'b0; end
			if (off == 10'h008) begin irq[1] <= 1'b0; armed[1] <= 1'b0; end
		end
		if (reg_cs && reg_we) begin
			case (off)
			10'h000, 10'h100: addr[0][31:16] <= merge16(addr[0][31:16], reg_din, reg_be);
			10'h002, 10'h102: addr[0][15:0]  <= merge16(addr[0][15:0],  reg_din, reg_be);
			10'h008, 10'h200: addr[1][31:16] <= merge16(addr[1][31:16], reg_din, reg_be);
			10'h00A, 10'h202: addr[1][15:0]  <= merge16(addr[1][15:0],  reg_din, reg_be);
			10'h004: tc[0] <= {16'd0, reg_din};
			10'h00C: tc[1] <= {16'd0, reg_din};
			10'h104: tc[0][31:16] <= merge16(tc[0][31:16], reg_din, reg_be);
			10'h106: tc[0][15:0]  <= merge16(tc[0][15:0],  reg_din, reg_be);
			10'h204: tc[1][31:16] <= merge16(tc[1][31:16], reg_din, reg_be);
			10'h206: tc[1][15:0]  <= merge16(tc[1][15:0],  reg_din, reg_be);
			10'h006: arm(1'b0, reg_din);
			10'h00E: arm(1'b1, reg_din);
			10'h108: begin
				ctrl[0] <= reg_din & 16'h7FFF;
				if (reg_din[15]) arm(1'b0, reg_din);
			end
			10'h208: begin
				ctrl[1] <= reg_din & 16'h7FFF;
				if (reg_din[15]) arm(1'b1, reg_din);
			end
			10'h014: begin
				if (reg_din[4]) armed[0] <= 1'b0;
				if (reg_din[5]) armed[1] <= 1'b0;
			end
			default: ;
			endcase
		end

		// ---- one byte at a time ----
		case (xs)
		X_IDLE: if ((want0 || want1) && !(reg_cs && reg_we)) begin
			ch      <= !want0;
			dack_ch <= !want0;
			if (ctrl[!want0][2]) begin
				// out: memory byte first, then to the device
				mreq  <= 1'b1; mwe <= 1'b0; maddr <= addr[!want0];
				xs    <= X_MEM;
			end
			else begin
				// in: take the byte from the device, then write memory
				dack_rd <= 1'b1;
				mwdata  <= dack_rdata;
				mreq    <= 1'b1; mwe <= 1'b1; maddr <= addr[!want0];
				xs      <= X_MEM;
			end
		end
		X_MEM: if (mack || merr) begin
			mreq <= 1'b0;
			if (merr) begin
				armed[ch] <= 1'b0;              // bus error: stop the channel
				if (ctrl[ch][0]) irq[ch] <= 1'b1;
				xs <= X_IDLE;
			end
			else if (mwe) begin
				count(ch);
				xs <= X_IDLE;
			end
			else begin
				dack_wdata <= mbyte;
				xs <= X_DEV;
			end
		end
		X_DEV: begin
			dack_wr <= 1'b1;
			count(ch);
			xs <= X_IDLE;
		end
		default: xs <= X_IDLE;
		endcase
	end
end

endmodule
