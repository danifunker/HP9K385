// Unit bench for rtl/sn76494.sv: tone frequency f = clock / (4 N) at the
// HP clock (333,333 Hz, STEP_DIV 198 at 33 MHz), attenuation 15 = silent.
`timescale 1ns/1ps
module tb_sn76494;
reg clk = 0, reset = 1;
always #15.1515 clk = !clk;                  // 33 MHz
reg wr = 0; reg [7:0] din = 0;
wire signed [15:0] audio;
sn76494 dut(.clk(clk), .reset(reset), .wr(wr), .din(din), .audio(audio));
task w(input [7:0] d); begin @(negedge clk); wr = 1; din = d; @(negedge clk); wr = 0; end endtask
integer errors = 0, edges = 0;
reg prev = 0;
real t0, f;
initial begin
	repeat (3) @(posedge clk); reset = 0;
	// channel 0: N = 100 -> 833.3 Hz, attenuation 0; others silent
	w(8'h84); w(8'h06);                         // N low 4 = 4, high 6 = 6 -> 0x64 = 100
	w(8'h90);                                   // ch0 attenuation 0
	repeat (100000) @(posedge clk);
	t0 = $realtime; edges = 0;
	repeat (3300000) begin @(posedge clk); if ((audio > 0) != prev) begin edges = edges + 1; prev = audio > 0; end end
	f = edges / 2.0 / (($realtime - t0) * 1e-9);
	$display("tone: %0.1f Hz (expect 833.3)", f);
	if (f < 820 || f > 846) begin $display("FAIL frequency"); errors = errors + 1; end
	w(8'h9F);                                   // ch0 off: all channels silent -> constant output
	repeat (2000) @(posedge clk);
	prev = audio > 0; edges = 0;
	repeat (200000) begin @(posedge clk); if ((audio > 0) != prev) edges = edges + 1; end
	if (edges != 0) begin $display("FAIL silence (%0d edges)", edges); errors = errors + 1; end
	if (errors == 0) $display("ALL TESTS PASSED"); else $display("TEST FAILED (%0d)", errors);
	$finish;
end
endmodule
