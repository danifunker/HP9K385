// Unit bench for rtl/msm58321.sv: set from the MiSTer RTC, count through
// year end, leap / non-leap February, 12-hour mode, host register access.
`timescale 1ns/1ps
module tb_msm58321;
reg clk = 0, reset = 1;
always #5 clk = !clk;
reg cs2 = 0, rd = 0, wr = 0, aw = 0;
reg [3:0] din = 0;
wire [3:0] dout;
reg [64:0] rtc = 0;
msm58321 #(.CLK_HZ(1000)) dut(.clk(clk), .reset(reset), .cs2(cs2), .read(rd), .write(wr), .address_write(aw),
	.din(din), .dout(dout), .rtc_set(rtc));

integer errors = 0;
task setrtc(input [7:0] yy, mo, dd, hh, mi, ss, input [3:0] w);
	begin @(negedge clk); rtc = {~rtc[64], 12'd0, w, yy, mo, dd, hh, mi, ss}; @(negedge clk); end
endtask
task rreg(input [3:0] a, output [3:0] v);
	begin
		@(negedge clk); cs2 = 1; din = a; aw = 1; @(negedge clk); aw = 0; rd = 1; #1 v = dout; @(negedge clk); rd = 0; cs2 = 0;
	end
endtask
task wreg(input [3:0] a, input [3:0] v);
	begin
		@(negedge clk); cs2 = 1; din = a; aw = 1; @(negedge clk); aw = 0; din = v; wr = 1; @(negedge clk); wr = 0; cs2 = 0;
	end
endtask
task readtime(output [47:0] t);   // yymmddhhmmss
	reg [3:0] n [0:12];
	integer k;
	begin
		for (k = 0; k <= 12; k = k + 1) rreg(k, n[k]);
		t = {n[12], n[11], n[10], n[9], n[8], n[7], n[5] & 4'h3, n[4], n[3], n[2], n[1], n[0]};
	end
endtask
task seconds(input integer s); repeat (1000 * s) @(posedge clk); endtask
task check(input [255:0] what, input [47:0] got, input [47:0] exp);
	if (got !== exp) begin $display("FAIL %0s: %h expected %h", what, got, exp); errors = errors + 1; end
endtask

reg [47:0] t;
reg [3:0] v;
initial begin
	// the MiSTer sends its time while the core is still in reset (ROM
	// download): it must be applied once reset ends
	repeat (3) @(posedge clk);
	setrtc(8'h26, 8'h10, 8'h15, 8'h19, 8'h30, 8'h00, 4'd4);
	repeat (3) @(posedge clk); reset = 0;
	readtime(t); check("time sent during reset", t, 48'h261015_193000);
	// a machine reset keeps the time (battery-backed)
	@(negedge clk); reset = 1; repeat (5) @(posedge clk); @(negedge clk); reset = 0;
	readtime(t); check("time kept across reset", t, 48'h261015_193000);
	setrtc(8'h99, 8'h12, 8'h31, 8'h23, 8'h59, 8'h58, 4'd5);
	readtime(t); check("set", t, 48'h991231_235958);
	seconds(3);
	readtime(t); check("year end", t, 48'h000101_000001);
	rreg(6, v); check("weekday", v, 4'd6);

	setrtc(8'h24, 8'h02, 8'h28, 8'h23, 8'h59, 8'h59, 4'd3);
	seconds(1); readtime(t); check("leap Feb 29", t, 48'h240229_000000);
	setrtc(8'h23, 8'h02, 8'h28, 8'h23, 8'h59, 8'h59, 4'd2);
	seconds(1); readtime(t); check("non-leap Mar 1", t, 48'h230301_000000);
	setrtc(8'h23, 8'h04, 8'h30, 8'h23, 8'h59, 8'h59, 4'd0);
	seconds(1); readtime(t); check("30-day month", t, 48'h230501_000000);

	// 12-hour mode: 11:59:59 PM -> 12:00:00 AM next day
	wreg(5, 4'b0101);  wreg(4, 4'd1);             // 12-hour, PM, 11
	wreg(3, 4'd5); wreg(2, 4'd9); wreg(1, 4'd5); wreg(0, 4'd9);
	wreg(8, 4'd1); wreg(7, 4'd5);
	seconds(1);
	rreg(5, v); check("12h AM after midnight", v, 4'b0001);
	rreg(4, v); check("12h hour 12", v, 4'd2);
	rreg(7, v); check("12h next day", v, 4'd6);
	rreg(13, v); check("reset reg reads 0", v, 4'd0);
	@(negedge clk); cs2 = 0; rd = 1; #1 if (dout !== 4'hF) begin $display("FAIL deselected"); errors = errors + 1; end
	rd = 0;

	if (errors == 0) $display("ALL TESTS PASSED"); else $display("TEST FAILED (%0d)", errors);
	$finish;
end
endmodule
