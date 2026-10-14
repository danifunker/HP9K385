// Unit bench for rtl/vram_ddr3.sv: random DDRAM_BUSY and read latency, a
// byte-addressed reference memory checked in little-endian DDR3 order (so
// the framebuffer sees pixel x at byte x), mixed reads and byte-enabled writes.
`timescale 1ns/1ps
module tb_vram_ddr3;
reg clk = 0, reset = 1;
always #5 clk = !clk;

reg         req = 0, we = 0;
reg  [21:2] addr = 0;
reg   [3:0] be = 0;
reg  [31:0] wdata = 0;
wire        ack;
wire [31:0] rdata;
reg         busy = 0;
wire  [7:0] burstcnt;
wire [28:0] daddr;
reg  [63:0] dout = 0;
reg         dout_ready = 0;
wire        rd, wr;
wire [63:0] din;
wire  [7:0] dbe;

vram_ddr3 #(.BASE(29'h0600_0000)) dut (.clk(clk), .reset(reset), .req(req), .we(we), .addr(addr), .be(be),
	.wdata(wdata), .ack(ack), .rdata(rdata), .DDRAM_BUSY(busy), .DDRAM_BURSTCNT(burstcnt),
	.DDRAM_ADDR(daddr), .DDRAM_DOUT(dout), .DDRAM_DOUT_READY(dout_ready), .DDRAM_RD(rd),
	.DDRAM_DIN(din), .DDRAM_BE(dbe), .DDRAM_WE(wr));

// DDR3 model: byte memory at (word - BASE) * 8, Avalon accept when !busy
reg [7:0] mem [0:65535];
reg [7:0] ref_ [0:65535];
integer pend_lat = -1;
reg [28:0] pend_addr;
integer errors = 0, i, n, k;
always @(posedge clk) begin
	dout_ready <= 0;
	busy <= ($random & 3) == 0;
	if (!busy && wr) begin
		for (k = 0; k < 8; k = k + 1)
			if (dbe[k]) mem[(daddr - 29'h0600_0000) * 8 + k] <= din[k*8 +: 8];
	end
	if (!busy && rd) begin pend_lat <= 3 + ($random & 7); pend_addr <= daddr; end
	if (pend_lat > 0) pend_lat <= pend_lat - 1;
	if (pend_lat == 0) begin
		for (k = 0; k < 8; k = k + 1) dout[k*8 +: 8] <= mem[(pend_addr - 29'h0600_0000) * 8 + k];
		dout_ready <= 1;
		pend_lat <= -1;
	end
end

task access(input w, input [15:0] a, input [3:0] b, input [31:0] d);
	begin
		@(negedge clk); req = 1; we = w; addr = {6'd0, a[15:2]}; be = b; wdata = d;
		@(posedge clk); while (!ack) @(posedge clk);
		#1;
		if (!w) begin
			if (rdata !== {ref_[a], ref_[a+1], ref_[a+2], ref_[a+3]}) begin
				if (errors < 5) $display("FAIL read %h: %h expected %h", a, rdata, {ref_[a], ref_[a+1], ref_[a+2], ref_[a+3]});
				errors = errors + 1;
			end
		end
		@(negedge clk); req = 0;
	end
endtask

reg [15:0] a;
reg [3:0] b;
reg [31:0] d;
initial begin
	for (i = 0; i < 65536; i = i + 1) begin mem[i] = 0; ref_[i] = 0; end
	repeat (3) @(posedge clk); reset = 0;
	for (n = 0; n < 4000; n = n + 1) begin
		a = $random & 16'h0FFC; b = $random; d = $random;
		if ($random & 1) begin
			if (b[3]) ref_[a]   = d[31:24];
			if (b[2]) ref_[a+1] = d[23:16];
			if (b[1]) ref_[a+2] = d[15:8];
			if (b[0]) ref_[a+3] = d[7:0];
			access(1, a, b, d);
		end
		else access(0, a, 4'hF, 0);
	end
	repeat (20) @(posedge clk);
	// the framebuffer's view: DDR3 bytes in address order are the pixels
	for (i = 0; i < 4096; i = i + 1)
		if (mem[i] !== ref_[i]) begin
			if (errors < 10) $display("FAIL ddr byte %h: %h expected %h", i, mem[i], ref_[i]);
			errors = errors + 1;
		end
	if (burstcnt !== 8'd1) begin $display("FAIL burstcnt"); errors = errors + 1; end
	if (errors == 0) $display("ALL TESTS PASSED"); else $display("TEST FAILED (%0d)", errors);
	$finish;
end
endmodule
