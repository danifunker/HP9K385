// Unit bench for rtl/catseye.sv against a byte-array reference.
// Build and run: see tb/README.md.
// Checks: host longword write/read through PRR; window moves that overlap
// in all four directions (copy, rule 3); clear (rule 0); per-plane rules
// (a colour fill); clipping; two-bank FB enable.
`timescale 1ns/1ps
module tb_catseye;
reg clk = 0, reset = 1;
always #5 clk = !clk;

reg         reg_cs = 0, reg_we = 0;
reg  [10:0] reg_word = 0;
reg   [1:0] reg_be = 0;
reg  [15:0] reg_din = 0;
wire [15:0] reg_dout;
reg         cpu_req = 0, cpu_we = 0;
reg  [20:2] cpu_addr = 0;
reg   [3:0] cpu_be = 0;
reg  [31:0] cpu_wdata = 0;
wire        cpu_ack;
wire [31:0] cpu_rdata;
wire        vr_req, vr_we;
wire [21:2] vr_addr;
wire  [3:0] vr_be;
wire [31:0] vr_wdata;
reg         vr_ack = 0;
reg  [31:0] vr_rdata = 0;
wire        irq, busy, unsupported, in_vblank;
wire  [7:0] display_enable;

catseye #(.FRAME_CLKS(1000), .VBL_CLKS(100)) dut (
	.clk(clk), .reset(reset), .card_reset(1'b0),
	.reg_cs(reg_cs), .reg_we(reg_we), .reg_word(reg_word), .reg_be(reg_be), .reg_din(reg_din), .reg_dout(reg_dout),
	.cpu_req(cpu_req), .cpu_we(cpu_we), .cpu_addr(cpu_addr), .cpu_be(cpu_be), .cpu_wdata(cpu_wdata),
	.cpu_ack(cpu_ack), .cpu_rdata(cpu_rdata),
	.vr_req(vr_req), .vr_we(vr_we), .vr_addr(vr_addr), .vr_be(vr_be), .vr_wdata(vr_wdata),
	.vr_ack(vr_ack), .vr_rdata(vr_rdata),
	.irq(irq), .in_vblank(in_vblank), .display_enable(display_enable), .busy(busy), .unsupported(unsupported));

// VRAM: 2 banks x 2048 x 1024 bytes, 2-clock latency
reg [7:0] vram [0:(4<<20)-1];
reg [7:0] ref_ [0:(4<<20)-1];
integer lat = 0;
always @(posedge clk) begin
	vr_ack <= 0;
	if (vr_req && !vr_ack) begin
		if (lat == 2) begin
			lat <= 0;
			if (vr_we) begin
				if (vr_be[3]) vram[{vr_addr, 2'd0}] <= vr_wdata[31:24];
				if (vr_be[2]) vram[{vr_addr, 2'd1}] <= vr_wdata[23:16];
				if (vr_be[1]) vram[{vr_addr, 2'd2}] <= vr_wdata[15:8];
				if (vr_be[0]) vram[{vr_addr, 2'd3}] <= vr_wdata[7:0];
			end
			vr_rdata <= {vram[{vr_addr, 2'd0}], vram[{vr_addr, 2'd1}], vram[{vr_addr, 2'd2}], vram[{vr_addr, 2'd3}]};
			vr_ack <= 1;
		end
		else lat <= lat + 1;
	end
end

integer errors = 0;
task wreg(input [10:0] w, input [15:0] d);
	begin @(negedge clk); reg_cs = 1; reg_we = 1; reg_word = w; reg_be = 2'b11; reg_din = d;
	      @(negedge clk); reg_cs = 0; reg_we = 0; end
endtask
task hostw(input [20:0] a, input [31:0] d, input [3:0] be);
	begin @(negedge clk); cpu_req = 1; cpu_we = 1; cpu_addr = a[20:2]; cpu_be = be; cpu_wdata = d;
	      @(posedge clk); while (!cpu_ack) @(posedge clk); @(negedge clk); cpu_req = 0; end
endtask
task hostr(input [20:0] a, output [31:0] d);
	begin @(negedge clk); cpu_req = 1; cpu_we = 0; cpu_addr = a[20:2];
	      @(posedge clk); while (!cpu_ack) @(posedge clk); #1 d = cpu_rdata; @(negedge clk); cpu_req = 0; end
endtask
task rreg_chk(input [10:0] w, input [15:0] exp);
	begin
		@(negedge clk); reg_cs = 1; reg_we = 0; reg_word = w; #1;
		if (reg_dout !== exp) begin $display("FAIL pattern read %h: %h expected %h", w, reg_dout, exp); errors = errors + 1; end
		@(negedge clk); reg_cs = 0;
	end
endtask
task wait_idle; begin @(posedge clk); @(posedge clk); while (busy) @(posedge clk); end endtask

// rules per plane: bank 0 PRR/WRR; tcwen picks the planes
task set_rule(input [7:0] planes, input [3:0] prr_rule, input [3:0] wrr_rule);
	begin wreg(11'h284, {planes, 8'h00}); wreg(11'h281, {4'h0, prr_rule, 8'h00}); wreg(11'h283, {12'h0, wrr_rule}); end
endtask

function [7:0] rule1;   // reference per-bit rule
	input [3:0] r; input [7:0] s, d, en;
	integer n;
	for (n = 0; n < 8; n = n + 1) rule1[n] = en[n] ? r[3 - {s[n], d[n]}] : d[n];
endfunction

integer x, y, sxx, syy, dxx, dyy, w, h, i;
reg [7:0] snap [0:2047];
reg [31:0] rd;
task ref_move(input integer sx0, sy0, dx0, dy0, w0, h0, input [3:0] r, input [7:0] en,
              input integer cl, cr, ct, cb, input clip);
	integer xx, yy;
	reg [7:0] tmp [0:(1<<20)-1];
	begin
		for (yy = 0; yy < h0; yy = yy + 1) for (xx = 0; xx < w0; xx = xx + 1)
			tmp[yy * 1024 + xx] = ref_[(sy0 + yy) * 2048 + sx0 + xx];
		for (yy = 0; yy < h0; yy = yy + 1) for (xx = 0; xx < w0; xx = xx + 1)
			if (!clip || (dx0 + xx >= cl && dx0 + xx <= cr && dy0 + yy >= ct && dy0 + yy <= cb))
				ref_[(dy0 + yy) * 2048 + dx0 + xx] = rule1(r, tmp[yy * 1024 + xx], ref_[(dy0 + yy) * 2048 + dx0 + xx], en);
	end
endtask
task move(input integer sx0, sy0, dx0, dy0, w0, h0);
	begin
		wreg(11'h108, sx0); wreg(11'h109, sy0); wreg(11'h10A, dx0); wreg(11'h10B, dy0);
		wreg(11'h104, w0); wreg(11'h185, h0);    // height via the T register starts it
		wait_idle;
	end
endtask
task compare(input [255:0] what, input integer x0, y0, w0, h0);
	integer xx, yy, bad;
	begin
		bad = 0;
		for (yy = y0; yy < y0 + h0; yy = yy + 1) for (xx = x0; xx < x0 + w0; xx = xx + 1)
			if (vram[yy * 2048 + xx] !== ref_[yy * 2048 + xx]) begin
				if (bad < 4) $display("  %0s: (%0d,%0d) got %h expected %h", what, xx, yy, vram[yy * 2048 + xx], ref_[yy * 2048 + xx]);
				bad = bad + 1;
			end
		if (bad) begin $display("FAIL %0s: %0d pixels", what, bad); errors = errors + 1; end
		else $display("ok   %0s", what);
	end
endtask

initial begin
	for (i = 0; i < (4 << 20); i = i + 1) begin vram[i] = 0; ref_[i] = 0; end
	repeat (4) @(posedge clk); reset = 0;

	wreg(11'h280, 16'hFF00);          // FBEN1: all planes
	set_rule(8'hFF, 4'd3, 4'd3);      // host: source, mover: source
	wreg(11'h103, 16'h0090);          // RUG_SC: window move

	// host writes through PRR 3, byte enables
	for (y = 0; y < 64; y = y + 1) for (x = 0; x < 96; x = x + 4)
		hostw(y * 2048 + x, {8'(x*7+y), 8'(x*7+y+1), 8'(x*5^y), 8'(y*3+x)}, 4'hF);
	for (y = 0; y < 64; y = y + 1) for (x = 0; x < 96; x = x + 4) begin
		ref_[y*2048+x] = x*7+y; ref_[y*2048+x+1] = x*7+y+1; ref_[y*2048+x+2] = (x*5)^y; ref_[y*2048+x+3] = y*3+x;
	end
	hostw(5 * 2048 + 8, 32'hAABBCCDD, 4'b0110);
	ref_[5*2048+9] = 8'hBB; ref_[5*2048+10] = 8'hCC;
	compare("host writes", 0, 0, 96, 64);
	hostr(5 * 2048 + 8, rd);
	if (rd !== {ref_[5*2048+8], 8'hBB, 8'hCC, ref_[5*2048+11]}) begin $display("FAIL host read %h", rd); errors = errors + 1; end

	// overlapping copies in all four directions, odd sizes and alignments
	ref_move(10, 5, 13, 7, 37, 9, 4'd3, 8'hFF, 0, 0, 0, 0, 0);  move(10, 5, 13, 7, 37, 9);  compare("move right/down", 0, 0, 96, 64);
	ref_move(20, 20, 17, 18, 41, 11, 4'd3, 8'hFF, 0, 0, 0, 0, 0); move(20, 20, 17, 18, 41, 11); compare("move left/up", 0, 0, 96, 64);
	ref_move(8, 30, 9, 29, 50, 12, 4'd3, 8'hFF, 0, 0, 0, 0, 0);  move(8, 30, 9, 29, 50, 12);  compare("move right/up", 0, 0, 96, 64);
	ref_move(40, 2, 36, 6, 33, 10, 4'd3, 8'hFF, 0, 0, 0, 0, 0);  move(40, 2, 36, 6, 33, 10);  compare("move left/down", 0, 0, 96, 64);
	ref_move(0, 0, 4, 40, 64, 8, 4'd3, 8'hFF, 0, 0, 0, 0, 0);    move(0, 0, 4, 40, 64, 8);    compare("aligned copy", 0, 0, 96, 64);
	// a group of four ending exactly at the rectangle edge, both directions
	ref_move(6, 0, 2, 44, 45, 3, 4'd3, 8'hFF, 0, 0, 0, 0, 0);    move(6, 0, 2, 44, 45, 3);    compare("edge group, rightward", 0, 0, 96, 64);
	ref_move(1, 0, 5, 54, 40, 3, 4'd3, 8'hFF, 0, 0, 0, 0, 0);    move(1, 0, 5, 54, 40, 3);    compare("edge group, leftward", 0, 0, 96, 64);

	// clear (rule 0) of an unaligned rectangle
	set_rule(8'hFF, 4'd3, 4'd0);
	ref_move(3, 3, 3, 3, 29, 5, 4'd0, 8'hFF, 0, 0, 0, 0, 0);     move(3, 3, 3, 3, 29, 5);     compare("clear", 0, 0, 96, 64);

	// colour fill: planes 0-3 set, 4-7 clear
	set_rule(8'h0F, 4'd3, 4'd15);
	set_rule(8'hF0, 4'd3, 4'd0);
	wreg(11'h284, 16'hFF00);
	for (y = 50; y < 58; y = y + 1) for (x = 5; x < 70; x = x + 1) ref_[y*2048+x] = 8'h0F;
	move(0, 0, 5, 50, 65, 8);
	compare("colour fill", 0, 0, 96, 64);

	// clipped copy with plane enable 0x3C
	set_rule(8'hFF, 4'd3, 4'd3);
	wreg(11'h280, 16'h3C00);
	wreg(11'h10C, 20); wreg(11'h10D, 44); wreg(11'h10E, 12); wreg(11'h10F, 15); wreg(11'h102, 16'h0080);
	ref_move(0, 0, 10, 10, 60, 10, 4'd3, 8'h3C, 20, 44, 12, 15, 1); move(0, 0, 10, 10, 60, 10);
	compare("clipped, planes 3C", 0, 0, 96, 64);
	wreg(11'h102, 16'h0000);

	// host write with per-plane PRR (planes 0-1 xor, others nop) and partial FB enable
	wreg(11'h280, 16'h0F00);
	set_rule(8'h03, 4'd6, 4'd3);
	set_rule(8'hFC, 4'd5, 4'd3);
	hostw(60 * 2048 + 16, 32'hFFFF_FFFF, 4'hF);
	for (x = 16; x < 20; x = x + 1) ref_[60*2048+x] = ref_[60*2048+x] ^ 8'h03;
	compare("per-plane host rules", 0, 0, 96, 64);

	// pattern fill (TRRCTL bit 8, TRR $F0): each plane draws its own 16x16 pattern
	wreg(11'h280, 16'hFF00);
	wreg(11'h284, 16'hFF00);                  // all planes write-enabled
	for (i = 0; i < 128; i = i + 1) wreg(11'h200 + i, 16'(i * 16'h9E37 ^ 16'h5A5A));
	rreg_chk(11'h200 + 37, 16'(37 * 16'h9E37 ^ 16'h5A5A));
	wreg(11'h289, 16'h0100);                  // TRRCTL1: pattern
	wreg(11'h286, 16'hF000);                  // TRR1 = $F0
	for (y = 21; y < 21 + 13; y = y + 1) for (x = 6; x < 6 + 37; x = x + 1)
		for (i = 0; i < 8; i = i + 1)
			ref_[y*2048+x][i] = ((i * 16 + (y & 15)) * 16'h9E37 ^ 16'h5A5A) >> (x & 15);
	move(0, 0, 6, 21, 37, 13);
	compare("pattern fill", 0, 0, 96, 64);
	wreg(11'h289, 16'h0000);

	if (unsupported) begin $display("FAIL unsupported flagged"); errors = errors + 1; end
	if (errors == 0) $display("ALL TESTS PASSED"); else $display("TEST FAILED (%0d)", errors);
	$finish;
end
endmodule
