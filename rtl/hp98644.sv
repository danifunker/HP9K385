//============================================================================
//  hp98644 — HP 98644A serial interface (select code 9, $690000), an
//  INS8250 on the card.  Reference: MAME bus/hp_dio/hp98644.cpp, except that
//  the interrupt is wired (a MAME gap) and loopback is the 8250's own.
//
//  Registers (16-bit words; the 8250 on the low byte of words 8-15):
//    +$00  read $02 (ID) / write: card reset
//    +$02  control: bit 7 IE; reads IE and bit 6 = interrupt requested in
//          both bytes | (level-3) << 4
//    +$11..+$1F  8250 register n at +$10 + 2n + 1
//  Interrupt level 5 (switch default).  2.4576 MHz baud crystal.
//============================================================================

module hp98644
(
	input             clk,
	input             reset,

	input             reg_cs,
	input             reg_we,
	input       [5:1] reg_off,             // word address within the card window
	input       [1:0] reg_be,
	input      [15:0] reg_din,
	output reg [15:0] reg_dout,
	output            irq,                 // level 5

	output            txd,
	input             rxd,
	output            rts_n, dtr_n,
	input             cts_n, dsr_n, dcd_n, ri_n,

	output            tx_stb,              // debug: byte written for transmission
	output      [7:0] tx_byte
);

reg        ie;
reg        card_reset;
wire       is_uart = reg_off[4];          // words 8-15
wire [7:0] uart_dout;
wire       uart_int;

uart8250 uart (
	.clk(clk),
	.reset(reset || card_reset),
	.cs(reg_cs && is_uart && reg_be[0]),
	.we(reg_we),
	.rs(reg_off[3:1]),
	.din(reg_din[7:0]),
	.dout(uart_dout),
	.intr(uart_int),
	.txd(txd),
	.rxd(rxd),
	.cts_n(cts_n), .dsr_n(dsr_n), .ri_n(ri_n), .dcd_n(dcd_n),
	.rts_n(rts_n), .dtr_n(dtr_n),
	.tx_stb(tx_stb),
	.tx_byte(tx_byte)
);

assign irq = ie && uart_int;

always @(*) begin
	if (is_uart) reg_dout = {8'hFF, uart_dout};
	else case (reg_off[3:1])
	3'd0: reg_dout = 16'h0002;
	// bit 7 IE, bit 6 interrupt requested (the 8250's INTR), 5:4 level - 3.
	// HP-UX's dispatcher claims a level-5 interrupt for this card only when
	// bits 7 and 6 are both set; without bit 6 it never ran the driver and
	// level 5 stormed (MAME leaves the 98644's interrupt unwired).
	3'd1: reg_dout = {ie, uart_int, 6'd0, ie, uart_int, 2'd2, 4'd0};
	default: reg_dout = 16'hFFFF;
	endcase
end

always @(posedge clk) begin
	card_reset <= 1'b0;
	if (reset) ie <= 1'b0;
	else if (reg_cs && reg_we && !is_uart) begin
		if (reg_off[3:1] == 3'd0) begin ie <= 1'b0; card_reset <= 1'b1; end
		if (reg_off[3:1] == 3'd1 && reg_be[0]) ie <= reg_din[7];
	end
end

endmodule
