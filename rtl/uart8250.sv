//============================================================================
//  uart8250 — National INS8250 / 16450 UART (no FIFO), for the HP 98644.
//
//  Registers (DLAB = LCR bit 7):
//    0  RBR (read) / THR (write); DLL when DLAB
//    1  IER: 0 data ready, 1 THR empty, 2 line status, 3 modem status; DLM when DLAB
//    2  IIR (read): 1 = nothing pending; 6 line status, 4 data, 2 THR empty, 0 modem
//    3  LCR: 1:0 word length - 5, 2 stop bits, 3 parity enable, 4 even, 5 stick,
//       6 break, 7 DLAB
//    4  MCR: 0 DTR, 1 RTS, 2 OUT1, 3 OUT2, 4 loopback
//    5  LSR: 0 DR, 1 OE, 2 PE, 3 FE, 4 BI, 5 THRE, 6 TEMT
//    6  MSR: 3:0 deltas (CTS, DSR, TERI, DCD), 7:4 CTS DSR RI DCD
//    7  scratch
//  Baud clock: XTAL / (16 * divisor), XTAL = 2.4576 MHz from a fractional
//  divider of clk.  Loopback ties TX to RX internally (the line idles) and
//  the modem inputs to DTR/RTS/OUT1/OUT2, as on the real part.
//
//  Host port: one register access per cs pulse, dout combinational, side
//  effects (RBR read, IIR read) on the clock edge.
//============================================================================

module uart8250
#(
	parameter CLK_HZ  = 33_000_000,
	parameter XTAL_HZ = 2_457_600
)
(
	input            clk,
	input            reset,

	input            cs,
	input            we,
	input      [2:0] rs,
	input      [7:0] din,
	output reg [7:0] dout,
	output           intr,

	output           txd,
	input            rxd,
	input            cts_n, dsr_n, ri_n, dcd_n,
	output           rts_n, dtr_n,

	output reg       tx_stb,           // debug: a byte was written to THR
	output reg [7:0] tx_byte
);

reg  [7:0] rbr, thr, ier, lcr, mcr, scr, dll, dlm;
reg        dr, oe, pe, fe, bi, thre, temt;
reg  [3:0] msr_d;
reg        thre_int;                   // THR-empty interrupt armed (cleared by IIR read / THR write)

wire dlab = lcr[7];
wire loop = mcr[4];

// ---- 16x baud tick: fractional XTAL, then the divisor ----
localparam [63:0] NCO_INC = (64'd1 << 32) * XTAL_HZ / CLK_HZ;
reg [31:0] nco;
wire [32:0] nco_next = {1'b0, nco} + {1'b0, NCO_INC[31:0]};
wire       xtal_tick = nco_next[32];
reg [15:0] bdiv;
wire [15:0] divisor = {dlm, dll};
wire       tick16 = xtal_tick && (bdiv <= 16'd1);
always @(posedge clk) begin
	nco <= nco_next[31:0];
	if (reset) bdiv <= 16'd0;
	else if (xtal_tick) bdiv <= (bdiv <= 16'd1) ? divisor : bdiv - 16'd1;
end

// ---- modem lines ----
wire cts = loop ? mcr[1] : !cts_n;
wire dsr = loop ? mcr[0] : !dsr_n;
wire ri  = loop ? mcr[2] : !ri_n;
wire dcd = loop ? mcr[3] : !dcd_n;
reg  cts_q, dsr_q, ri_q, dcd_q;
assign rts_n = !mcr[1];
assign dtr_n = !mcr[0];

// ---- transmitter ----
wire [3:0] nbits = 4'd5 + {2'd0, lcr[1:0]};
reg  [3:0] tx_tick;                     // 16 ticks per bit
reg  [3:0] tx_bit;                      // bits left in the frame
reg [11:0] tx_shift;
reg        tx_active, tx_line;
assign txd = loop ? 1'b1 : tx_line;

function parity_bit;
	input [7:0] d;
	input [3:0] n;
	reg p;
	integer k;
	begin
		p = 1'b0;
		for (k = 0; k < 8; k = k + 1) if (k < n) p = p ^ d[k];
		parity_bit = lcr[5] ? !lcr[4] : (lcr[4] ? p : !p);     // stick / even / odd
	end
endfunction

// a frame, LSB first: start, nbits data, parity if enabled, then stop (1s)
function [11:0] tx_frame;
	input [7:0] d;
	input [3:0] n;
	integer k;
	begin
		tx_frame = 12'hFFF;
		tx_frame[0] = 1'b0;
		for (k = 0; k < 8; k = k + 1) if (k < n) tx_frame[1 + k] = d[k];
		if (lcr[3]) tx_frame[1 + n] = parity_bit(d, n);
	end
endfunction

// ---- receiver ----
wire       rx_in = loop ? tx_line : rxd;
reg  [1:0] rx_sync;
reg        rx_active;
reg  [3:0] rx_tick, rx_bit;
reg  [8:0] rx_shift;
reg        rx_par;

wire [3:0] iir = (ier[2] && (oe || pe || fe || bi)) ? 4'h6 :
                 (ier[0] && dr)                     ? 4'h4 :
                 (ier[1] && thre_int)               ? 4'h2 :
                 (ier[3] && |msr_d)                 ? 4'h0 : 4'h1;
assign intr = !iir[0];

always @(*) begin
	case (rs)
	3'd0: dout = dlab ? dll : rbr;
	3'd1: dout = dlab ? dlm : {4'd0, ier[3:0]};
	3'd2: dout = {4'd0, iir};
	3'd3: dout = lcr;
	3'd4: dout = {3'd0, mcr[4:0]};
	3'd5: dout = {1'b0, temt, thre, bi, fe, pe, oe, dr};
	3'd6: dout = {dcd, ri, dsr, cts, msr_d};
	default: dout = scr;
	endcase
end

always @(posedge clk) begin
	tx_stb <= 1'b0;
	if (reset) begin
		ier <= 0; lcr <= 0; mcr <= 0; scr <= 0; dll <= 8'd12; dlm <= 0;
		dr <= 0; oe <= 0; pe <= 0; fe <= 0; bi <= 0; thre <= 1; temt <= 1; thre_int <= 0;
		msr_d <= 0; tx_active <= 0; tx_line <= 1; rx_active <= 0; rx_sync <= 2'b11;
		cts_q <= 0; dsr_q <= 0; ri_q <= 0; dcd_q <= 0;
	end
	else begin
		// reading LSR clears the errors it reported; done first so an error
		// the receiver flags in this same clock is kept for the next read
		if (cs && !we && rs == 3'd5) begin oe <= 1'b0; pe <= 1'b0; fe <= 1'b0; bi <= 1'b0; end

		// modem status deltas
		cts_q <= cts; dsr_q <= dsr; ri_q <= ri; dcd_q <= dcd;
		if (cts != cts_q) msr_d[0] <= 1'b1;
		if (dsr != dsr_q) msr_d[1] <= 1'b1;
		if (ri_q && !ri)  msr_d[2] <= 1'b1;       // trailing edge of RI
		if (dcd != dcd_q) msr_d[3] <= 1'b1;

		// ---- transmitter: load the shifter from THR ----
		if (!tx_active && !thre) begin
			tx_active <= 1'b1;
			tx_shift  <= tx_frame(thr, nbits);
			tx_bit    <= 4'd1 + nbits + (lcr[3] ? 4'd1 : 4'd0) + (lcr[2] ? 4'd2 : 4'd1);
			tx_tick   <= 4'd0;
			thre      <= 1'b1;
			thre_int  <= 1'b1;
			temt      <= 1'b0;
		end
		if (tx_active && tick16) begin
			if (tx_tick == 4'd0) begin
				if (tx_bit == 4'd0) begin
					tx_active <= 1'b0;
					tx_line   <= 1'b1;
					if (thre) temt <= 1'b1;
				end
				else begin
					tx_line  <= lcr[6] ? 1'b0 : tx_shift[0];   // break holds the line low
					tx_shift <= {1'b1, tx_shift[11:1]};
					tx_bit   <= tx_bit - 4'd1;
				end
			end
			tx_tick <= tx_tick + 4'd1;
		end

		// ---- receiver ----
		rx_sync <= {rx_sync[0], rx_in};
		if (tick16) begin
			if (!rx_active) begin
				if (!rx_sync[1]) begin rx_active <= 1'b1; rx_tick <= 4'd0; rx_bit <= 4'd0; end
			end
			else begin
				rx_tick <= rx_tick + 4'd1;
				if (rx_tick == 4'd7) begin                     // middle of the bit
					if (rx_bit == 4'd0) begin
						if (rx_sync[1]) rx_active <= 1'b0;     // false start
					end
					else if (rx_bit <= nbits)
						rx_shift <= {rx_sync[1], rx_shift[8:1]};
					else if (lcr[3] && rx_bit == nbits + 4'd1)
						rx_par <= rx_sync[1];
					else begin
						// stop bit: the character is in
						rx_active <= 1'b0;
						rbr <= rx_shift[8:1] >> (4'd8 - nbits);
						if (dr) oe <= 1'b1;
						dr <= 1'b1;
						if (!rx_sync[1]) fe <= 1'b1;
						if (lcr[3] && rx_par != parity_bit(rx_shift[8:1] >> (4'd8 - nbits), nbits)) pe <= 1'b1;
						if (!rx_sync[1] && rx_shift == 9'd0) bi <= 1'b1;
					end
					rx_bit <= rx_bit + 4'd1;
				end
			end
		end

		// ---- host ----
		if (cs && we) begin
			case (rs)
			3'd0: if (dlab) dll <= din;
			      else begin thr <= din; thre <= 1'b0; thre_int <= 1'b0; tx_stb <= 1'b1; tx_byte <= din; end
			3'd1: if (dlab) dlm <= din; else begin ier <= din & 8'h0F; if (din[1] && thre) thre_int <= 1'b1; end
			3'd3: lcr <= din;
			3'd4: mcr <= din & 8'h1F;
			3'd7: scr <= din;
			default: ;
			endcase
		end
		else if (cs) begin
			case (rs)
			3'd0: if (!dlab) dr <= 1'b0;
			3'd2: if (iir == 4'h2) thre_int <= 1'b0;
			3'd6: msr_d <= 4'd0;
			default: ;
			endcase
		end
	end
end

endmodule
