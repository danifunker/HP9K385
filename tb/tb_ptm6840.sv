// Unit bench for rtl/ptm6840.sv (iverilog -g2012 or verilator --binary).
//   - 16-bit continuous: time-out every latch+1 E clocks, IRQ, status
//     read + counter read clears the flag
//   - dual 8-bit T3 with O3 cascading into T2 (the Rev 2.0 ROM's setup)
//   - internal reset holds counters at their latches
`timescale 1ns/1ps
module tb_ptm6840;
reg clk = 0, reset = 1;
always #5 clk = !clk;
reg cs = 0, we = 0; reg [2:0] rs = 0; reg [7:0] din = 0;
wire [7:0] dout; wire irq; wire [2:0] out;
ptm6840 #(.TICK_DIV(4)) dut(.clk(clk), .reset(reset), .cs(cs), .we(we), .rs(rs),
	.din(din), .dout(dout), .irq(irq), .out(out));

integer errors = 0;
task wr(input [2:0] r, input [7:0] d);
	begin @(negedge clk); cs = 1; we = 1; rs = r; din = d; @(negedge clk); cs = 0; we = 0; end
endtask
task rd(input [2:0] r, output [7:0] d);
	begin @(negedge clk); cs = 1; we = 0; rs = r; #1 d = dout; @(negedge clk); cs = 0; end
endtask
task check(input [255:0] what, input [31:0] got, input [31:0] exp);
	if (got !== exp) begin $display("FAIL %0s: got %h expected %h", what, got, exp); errors = errors + 1; end
endtask
task eticks(input integer n); repeat (4 * n) @(posedge clk); endtask

reg [7:0] b, msb, lsb; reg [15:0] t2a, t3a, t2b, t3b;
integer k;
initial begin
	repeat (4) @(posedge clk); reset = 0;
	rd(1, b); check("status after reset", b, 8'h00);
	rd(2, msb); rd(3, lsb); check("T1 after reset", {msb, lsb}, 16'hFFFF);

	// T1: 16-bit continuous, internal clock, IRQ enabled, latch 9 -> period 10
	wr(1, 8'h01);              // CR2: select CR1
	wr(0, 8'h43);              // CR1: IE, internal clock, held in reset
	wr(2, 8'h00); wr(3, 8'h09);
	wr(0, 8'h42);              // release
	eticks(5);
	rd(2, msb); rd(3, lsb);
	if ({msb, lsb} > 16'd9 || {msb, lsb} < 16'd3) begin $display("FAIL T1 counting: %h", {msb, lsb}); errors = errors + 1; end
	check("no irq yet", irq, 0);
	eticks(8);
	check("irq after time-out", irq, 1);
	rd(1, b); check("status T1 + composite", b, 8'h81);
	rd(2, msb);                // status then counter read: clears
	@(posedge clk); #1 check("irq cleared", irq, 0);

	// held in reset: counters sit at their latches
	wr(0, 8'h43);
	eticks(20);
	rd(2, msb); rd(3, lsb); check("T1 held at latch", {msb, lsb}, 16'h0009);
	check("held clears irq", irq, 0);

	// ROM setup: CR3 = $84 (output enable, dual 8-bit, external C3),
	// CR2 = $01 (external C2 = O3, 16-bit), latches FFFF, release reset
	wr(1, 8'h00); wr(0, 8'h84);
	wr(1, 8'h01); wr(0, 8'h01);
	wr(4, 8'hFF); wr(5, 8'hFF); wr(6, 8'hFF); wr(7, 8'hFF);
	wr(0, 8'h00);
	rd(4, msb); rd(5, lsb); t2a = {msb, lsb};
	rd(6, msb); rd(7, lsb); t3a = {msb, lsb};
	eticks(3 * 65536 + 100);
	rd(4, msb); rd(5, lsb); t2b = {msb, lsb};
	rd(6, msb); rd(7, lsb); t3b = {msb, lsb};
	$display("T2 %h -> %h, T3 %h -> %h", t2a, t2b, t3a, t3b);
	check("T2 counted 3 O3 periods", t2a - t2b, 3);
	// three full 65536-clock periods return T3 to where it was; only the
	// ~100 extra clocks (plus bus overhead) show in the LSB
	if (t3a[15:8] != t3b[15:8] || t3a[7:0] - t3b[7:0] < 100 || t3a[7:0] - t3b[7:0] > 120) begin
		$display("FAIL T3 position: %h -> %h", t3a, t3b); errors = errors + 1;
	end

	if (errors == 0) $display("ALL TESTS PASSED"); else $display("TEST FAILED (%0d)", errors);
	$finish;
end
endmodule
