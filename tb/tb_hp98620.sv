// Unit bench for rtl/hp98620.sv: memory and device models, device -> memory
// and memory -> device transfers in byte / word / longword units through
// both register sets, interrupt level and clear-on-read, disarm, and a bus
// error stopping the channel.
`timescale 1ns/1ps
module tb_hp98620;
reg clk = 0, reset = 1;
always #5 clk = !clk;

reg         reg_cs = 0, reg_we = 0;
reg   [9:1] reg_word = 0;
reg   [1:0] reg_be = 2'b11;
reg  [15:0] reg_din = 0;
wire [15:0] reg_dout;
reg   [1:0] dmar = 0;
wire        dack_rd, dack_wr, dack_ch;
wire  [7:0] dack_wdata;
wire  [7:0] dack_rdata;
wire        mreq, mwe;
wire [31:0] maddr;
wire  [7:0] mwdata;
reg         mack = 0, merr = 0;
reg  [31:0] mrdata = 0;
wire  [7:1] irq_lvl;

hp98620 dut(.clk(clk), .reset(reset), .reg_cs(reg_cs), .reg_we(reg_we), .reg_word(reg_word), .reg_be(reg_be),
	.reg_din(reg_din), .reg_dout(reg_dout), .dmar(dmar), .dack_rd(dack_rd), .dack_wr(dack_wr), .dack_ch(dack_ch),
	.dack_wdata(dack_wdata), .dack_rdata(dack_rdata), .mreq(mreq), .mwe(mwe), .maddr(maddr), .mwdata(mwdata),
	.mack(mack), .mrdata(mrdata), .merr(merr), .irq_lvl(irq_lvl));

// memory: 4 KB at 0x1000; anything else bus-errors
reg [7:0] mem [0:4095];
integer lat = 0;
always @(posedge clk) begin
	mack <= 0; merr <= 0;
	if (mreq && !mack && !merr) begin
		if (lat == 2) begin
			lat <= 0;
			if (maddr < 32'h1000 || maddr >= 32'h2000) merr <= 1;
			else begin
				if (mwe) mem[maddr - 32'h1000] <= mwdata;
				mrdata <= 32'hEEEEEEEE;
				mrdata[(3 - maddr[1:0]) * 8 +: 8] <= mem[maddr - 32'h1000];
				mack <= 1;
			end
		end else lat <= lat + 1;
	end
end

// device: a source of bytes 'seq' and a sink recording what it was given;
// it requests while it has data (in) or room (out), like an SPC FIFO
integer dev_n = 0, dev_left = 0;
reg [7:0] sink [0:255];
integer sink_n = 0;
assign dack_rdata = 8'h40 + dev_n[7:0];
always @(posedge clk) begin
	if ($test$plusargs("trace") && (dack_rd || (mack && mwe)))
		$display("%0t rd=%b mack=%b maddr=%h tc0=%0d sub=%0d armed=%b", $time, dack_rd, mack, maddr, dut.tc[0], dut.sub[0], dut.armed);
	if (dack_rd) begin dev_n <= dev_n + 1; dev_left <= dev_left - 1; end
	if (dack_wr) begin sink[sink_n] <= dack_wdata; sink_n <= sink_n + 1; dev_left <= dev_left - 1; end
end

integer errors = 0, i;
task wr(input [9:0] off, input [15:0] d);
	begin @(negedge clk); reg_cs = 1; reg_we = 1; reg_word = off[9:1]; reg_din = d; @(negedge clk); reg_cs = 0; reg_we = 0; end
endtask
task rd(input [9:0] off, output [15:0] d);
	begin @(negedge clk); reg_cs = 1; reg_we = 0; reg_word = off[9:1]; #1 d = reg_dout; @(negedge clk); reg_cs = 0; end
endtask
task check(input [255:0] what, input [31:0] got, input [31:0] exp);
	if (got !== exp) begin $display("FAIL %0s: got %h expected %h", what, got, exp); errors = errors + 1; end
endtask
task run_until_disarmed(input ch);
	reg [15:0] st;
	integer guard;
	begin
		guard = 0;
		dmar[ch] = 1;
		do begin repeat (20) @(posedge clk); rd(ch ? 10'h00E : 10'h006, st); guard = guard + 1; end
		while (st[0] && guard < 500);
		dmar[ch] = 0;
	end
endtask

reg [15:0] st;
initial begin
	for (i = 0; i < 4096; i = i + 1) mem[i] = i[7:0] ^ 8'hA5;
	repeat (3) @(posedge clk); reset = 0;

	rd(10'h010, st); check("ID low", st, 16'h3230);
	rd(10'h012, st); check("ID high", st, 16'h4330);

	// channel 0, legacy registers: device -> memory, 10 bytes, IE, level 4
	dev_n = 0;
	wr(10'h000, 16'h0000); wr(10'h002, 16'h1100); wr(10'h004, 16'd9);
	wr(10'h006, 16'b0001_0001);                          // IE, level 3+1
	rd(10'h006, st); check("armed", st, 16'h0001);
	run_until_disarmed(0);
	for (i = 0; i < 10; i = i + 1) check("in byte", mem[16'h100 + i], 8'h40 + i);
	check("in no overrun", mem[16'h10A], 8'h0A ^ 8'hA5 ^ 8'h00);
	rd(10'h006, st); check("int status", st, 16'h0002);
	check("irq level 4", irq_lvl, 7'b0001000);
	rd(10'h000, st);                                     // clears it
	check("irq cleared", irq_lvl, 7'b0000000);

	// channel 1, 98620C registers: memory -> device, 3 words (6 bytes)
	sink_n = 0;
	wr(10'h200, 16'h0000); wr(10'h202, 16'h1200); wr(10'h204, 16'h0000); wr(10'h206, 16'd2);
	wr(10'h208, 16'h8006);                               // START, out, word, no IE
	run_until_disarmed(1);
	check("out count", sink_n, 6);
	for (i = 0; i < 6; i = i + 1) check("out byte", sink[i], ((16'h200 + i) & 8'hFF) ^ 8'hA5);
	check("no irq without IE", irq_lvl, 7'b0000000);
	rd(10'h202, st); check("address advanced", st, 16'h1206);

	// longword units through the legacy set: 2 units = 8 bytes in
	dev_n = 0;
	wr(10'h000, 16'h0000); wr(10'h002, 16'h1300); wr(10'h004, 16'd1);
	wr(10'h006, 16'h0100 | 16'b0110_0001);               // longword, IE, level 9 -> out of range for 7:1
	run_until_disarmed(0);
	for (i = 0; i < 8; i = i + 1) check("long byte", mem[16'h300 + i], 8'h40 + i);
	rd(10'h000, st);

	// bus error stops the channel and interrupts
	wr(10'h000, 16'h0000); wr(10'h002, 16'h0FFE); wr(10'h004, 16'd9);
	wr(10'h006, 16'b0011_0001);                          // IE, level 6
	run_until_disarmed(0);
	rd(10'h006, st); check("berr: disarmed + int", st, 16'h0002);
	check("berr irq level 6", irq_lvl, 7'b0100000);
	rd(10'h000, st);

	// general control disarms
	wr(10'h004, 16'd100); wr(10'h002, 16'h1000); wr(10'h006, 16'h0000);
	wr(10'h014, 16'h0010);
	rd(10'h006, st); check("disarmed by general control", st, 16'h0000);

	if (errors == 0) $display("ALL TESTS PASSED"); else $display("TEST FAILED (%0d)", errors);
	$finish;
end
endmodule
