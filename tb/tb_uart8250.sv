// Unit bench for rtl/uart8250.sv (Verilator: iverilog is very slow here): loopback data path, LSR / IIR, 8N1 and
// 7E1 framing over a TX->RX wire, a parity error, overrun, and the bit
// period against the 2.4576 MHz / 16 / divisor rate.
`timescale 1ns/1ps
module tb_uart8250;
reg clk = 0, reset = 1;
always #15.1515 clk = !clk;                 // 33 MHz
reg cs = 0, we = 0; reg [2:0] rs = 0; reg [7:0] din = 0;
wire [7:0] dout; wire intr, txd, rts_n, dtr_n, tx_stb; wire [7:0] tx_byte;
reg wire_loop = 1;                          // external TX -> RX
reg force_rx = 0, force_val = 1;
wire rxd = force_rx ? force_val : (wire_loop ? txd : 1'b1);
uart8250 dut(.clk(clk), .reset(reset), .cs(cs), .we(we), .rs(rs), .din(din), .dout(dout), .intr(intr),
	.txd(txd), .rxd(rxd), .cts_n(1'b1), .dsr_n(1'b1), .ri_n(1'b1), .dcd_n(1'b1), .rts_n(rts_n), .dtr_n(dtr_n),
	.tx_stb(tx_stb), .tx_byte(tx_byte));

integer errors = 0;
task w(input [2:0] r, input [7:0] d); begin @(negedge clk); cs = 1; we = 1; rs = r; din = d; @(negedge clk); cs = 0; we = 0; end endtask
task rd(input [2:0] r, output [7:0] d); begin @(negedge clk); cs = 1; we = 0; rs = r; #1 d = dout; @(negedge clk); cs = 0; end endtask
task check(input [255:0] what, input [7:0] got, input [7:0] exp);
	if (got !== exp) begin $display("FAIL %0s: %h expected %h", what, got, exp); errors = errors + 1; end
endtask
reg [7:0] lsr_seen;                         // the LSR read that showed DR (it also cleared the error bits)
task wait_dr; reg [7:0] l; integer g; begin g = 0; do begin rd(5, l); g = g + 1; end while (!l[0] && g < 20000); lsr_seen = l; end endtask

reg [7:0] v;
real t0, t1;
initial begin
	repeat (4) @(posedge clk); reset = 0;
	// divisor 2 -> 76800 baud; 8N1
	w(3, 8'h80); w(0, 8'd2); w(1, 8'd0); w(3, 8'h03);
	rd(5, v); check("LSR idle", v & 8'h61, 8'h60);
	rd(2, v); check("IIR none", v, 8'h01);
	// internal loopback
	w(4, 8'h10); wire_loop = 0;
	w(1, 8'h01);                             // data-ready interrupt
	w(0, 8'hA5); wait_dr;
	check("loopback int", intr, 1);
	rd(2, v); check("IIR data", v, 8'h04);
	rd(0, v); check("loopback data", v, 8'hA5);
	check("int cleared", intr, 0);
	rd(6, v); check("MSR loopback lines", v[7:4], 4'b0000);
	w(4, 8'h1F); rd(6, v); check("MSR loopback all set", v[7:4], 4'b1111);
	w(4, 8'h00); wire_loop = 1; rd(6, v);
	// THR empty interrupt
	w(1, 8'h02); rd(2, v); check("IIR THRE", v, 8'h02); rd(2, v); check("IIR THRE cleared by read", v, 8'h01);
	w(1, 8'h00);
	// 8N1 over the wire, measure the bit period on txd
	fork
		w(0, 8'h3C);
		begin @(negedge txd); t0 = $realtime; @(posedge txd); t1 = $realtime; end
	join
	wait_dr; rd(0, v); check("8N1 wire", v, 8'h3C);
	// 0x3C = 00111100: start + 2 low data bits = 3 bits low
	if ((t1 - t0) < 3 * 13020 * 0.98 || (t1 - t0) > 3 * 13020 * 1.02) begin
		$display("FAIL bit period: 3 bits = %0.0f ns", t1 - t0); errors = errors + 1;
	end
	// 7E1
	w(3, 8'h1A);
	w(0, 8'h55); wait_dr; check("7E1 no errors", lsr_seen & 8'h0E, 8'h00); rd(0, v); check("7E1 data", v, 8'h55);
	// odd parity sent to an even-parity receiver: switch LCR mid-way is awkward;
	// instead send with stick parity 1 (always 1) and receive even: 0x01 needs parity 1 -> ok, 0x03 needs 0 -> error
	do rd(5, v); while (!v[6]);              // transmitter idle before changing the format
	w(3, 8'h2A); w(0, 8'h03);
	do rd(5, v); while (!v[5]);              // in the shifter, framed with stick parity
	w(3, 8'h1A);
	wait_dr; check("parity error", lsr_seen & 8'h04, 8'h04); rd(0, v);
	// overrun: two characters without reading
	w(3, 8'h03); w(0, 8'h11); wait_dr; w(0, 8'h22);
	repeat (40000) @(posedge clk);
	rd(5, v); check("overrun", v & 8'h03, 8'h03);   // the read after the second character rd(0, v); check("overrun keeps last", v, 8'h22);
	if (errors == 0) $display("ALL TESTS PASSED"); else $display("TEST FAILED (%0d)", errors);
	$finish;
end
endmodule
