// Unit bench for rtl/scanout.sv + rtl/vram_ddr3.sv (Verilator): the core's
// own 98550A display.  A DDR3 Avalon model with bursts, random waitrequest
// and read latency holds both VRAM banks (video: a pattern, overlay: mostly
// 0 with a small "cursor" patch); a stand-in for the Nereid lookup returns
// {overlay, video, 0x5A} one clock later.  Two whole frames are checked
// pixel by pixel (every visible pixel, in order, with DE), along with the
// sync widths, while VRAM-port writes run concurrently and are read back.
`timescale 1ns/1ps
module tb_scanout;
reg clk = 0, reset = 1;
always #15 clk = !clk;

// ---- DDR3 model: 64-bit words at word address; bursts; random busy ----
localparam [28:0] BASE = 29'h0600_0000, OVL = 29'h0604_0000;
reg  [63:0] mem [0:(1 << 19) - 1];          // 4 MB: both banks
function [18:0] widx(input [28:0] a); widx = a[18:0] - BASE[18:0]; endfunction

wire        busy;
wire  [7:0] burstcnt;
wire [28:0] daddr;
reg  [63:0] dout;
reg         dready;
wire        drd;
wire [63:0] ddin;
wire  [7:0] dbe;
wire        dwe;
reg         busy_r = 0;
assign busy = busy_r;

integer rd_left = 0, rd_delay = 0;
reg [28:0] rd_addr;
always @(posedge clk) begin
	dready <= 0;
	busy_r <= ($random & 7) == 0;                // waitrequest about 1/8
	if (drd && !busy_r) begin
		rd_addr <= daddr; rd_left <= burstcnt; rd_delay <= 4 + ($random & 7);
	end
	if (dwe && !busy_r) begin
		for (int b = 0; b < 8; b++) if (dbe[b]) mem[widx(daddr)][b*8 +: 8] <= ddin[b*8 +: 8];
	end
	if (rd_left > 0) begin
		if (rd_delay > 0) rd_delay <= rd_delay - 1;
		else if (($random & 3) != 0) begin
			dout   <= mem[widx(rd_addr)];
			dready <= 1;
			rd_addr <= rd_addr + 1;
			rd_left <= rd_left - 1;
		end
	end
end

// ---- DUT ----
reg         vreq = 0, vwe = 0;
reg  [21:2] vaddr = 0;
reg   [3:0] vbe = 0;
reg  [31:0] vwdata = 0;
wire        vack;
wire [31:0] vrdata;
wire        f_req, f_ack, f_valid;
wire [28:0] f_addr;
wire [63:0] f_data;
wire  [7:0] pv, po;
reg  [23:0] prgb;
wire        hs, vs, de;
wire [23:0] rgb;

vram_ddr3 #(.BASE(BASE)) vram(.clk(clk), .reset(reset),
	.req(vreq), .we(vwe), .addr(vaddr), .be(vbe), .wdata(vwdata), .ack(vack), .rdata(vrdata),
	.f_req(f_req), .f_addr(f_addr), .f_ack(f_ack), .f_valid(f_valid), .f_data(f_data),
	.DDRAM_BUSY(busy), .DDRAM_BURSTCNT(burstcnt), .DDRAM_ADDR(daddr), .DDRAM_DOUT(dout),
	.DDRAM_DOUT_READY(dready), .DDRAM_RD(drd), .DDRAM_DIN(ddin), .DDRAM_BE(dbe), .DDRAM_WE(dwe));

scanout #(.BASE(BASE), .OVL(OVL)) dut(.clk(clk), .reset(reset),
	.f_req(f_req), .f_addr(f_addr), .f_ack(f_ack), .f_valid(f_valid), .f_data(f_data),
	.pix_video(pv), .pix_overlay(po), .pix_rgb(prgb), .hs(hs), .vs(vs), .de(de), .rgb(rgb));

always @(posedge clk) prgb <= {po, pv, 8'h5A};   // Nereid stand-in, one clock

// ---- expected pixels ----
function [7:0] vpix(input integer x, y); vpix = 8'((x * 7) ^ (y * 13) ^ (x >> 5)); endfunction
function [7:0] opix(input integer x, y);
	opix = (x >= 600 && x < 616 && y >= 500 && y < 516) ? 8'(1 + ((x + y) & 1)) : 8'd0;
endfunction

integer errors = 0;
integer x, y, k;
reg [7:0] ex_v [0:1279];

initial begin
	for (y = 0; y < 1024; y++) for (x = 0; x < 2048; x += 8) begin
		reg [63:0] wv, wo;
		for (k = 0; k < 8; k++) begin
			wv[k*8 +: 8] = (x + k < 1280) ? vpix(x + k, y) : 8'hEE;
			wo[k*8 +: 8] = (x + k < 1280) ? opix(x + k, y) : 8'h00;
		end
		mem[y * 256 + x / 8] = wv;
		mem[19'h40000 + y * 256 + x / 8] = wo;
	end
	repeat (10) @(posedge clk); reset = 0;
end

// concurrent VRAM-port writes to bank 0, beyond the visible area (x >= 1280),
// read back at the end
integer nw = 0;
initial begin
	@(negedge reset);
	repeat (2000) @(posedge clk);
	for (int i = 0; i < 300; i++) begin
		@(negedge clk);
		vreq = 1; vwe = 1; vaddr = 20'((i * 2048 + 1280 + (i % 64) * 4) >> 2); vbe = 4'hF; vwdata = 32'hC0DE0000 + i;
		@(posedge clk); while (!vack) @(posedge clk);
		@(negedge clk); vreq = 0; nw++;
		repeat ($urandom % 400) @(posedge clk);
	end
end

// ---- checker: every visible pixel of frames 1 and 2 ----
integer frame = 0, px = 0, py = 0, hsw = 0, last_hs = 0;
reg last_vs = 0, started = 0;
always @(posedge clk) if (!reset) begin
	last_vs <= vs;
	if (vs && !last_vs) begin
		if (started && (py != 1024 || px != 0)) begin
			$display("FAIL frame %0d ended at line %0d pixel %0d", frame, py, px); errors++;
		end
		frame <= frame + 1; started <= 1; px <= 0; py <= 0;
	end
	if (hs) hsw <= hsw + 1;
	else begin
		if (hsw != 0 && hsw != 32) begin $display("FAIL hsync width %0d", hsw); errors++; end
		hsw <= 0;
	end
	if (started && de && frame >= 1 && frame <= 2) begin
		if (rgb !== {opix(px, py), vpix(px, py), 8'h5A}) begin
			if (errors < 8) $display("FAIL frame %0d (%0d,%0d): %h want %h", frame, px, py, rgb, {opix(px, py), vpix(px, py), 8'h5A});
			errors++;
		end
		if (px == 1279) begin px <= 0; py <= py + 1; end else px <= px + 1;
	end
	if (frame == 3) begin
		for (int i = 0; i < 300; i++) begin
			if (mem[(i * 2048 + 1280 + (i % 64) * 4) / 8][((i % 64) * 4 % 8) * 8 +: 32] !== {8'(32'hC0DE0000 + i), 8'((32'hC0DE0000 + i) >> 8), 8'((32'hC0DE0000 + i) >> 16), 8'((32'hC0DE0000 + i) >> 24)}) begin
				if (errors < 8) $display("FAIL VRAM write %0d not in DDR3", i);
				errors++;
			end
		end
		$display("frames checked: 2, VRAM writes during scanout: %0d", nw);
		if (errors == 0) $display("ALL TESTS PASSED"); else $display("TEST FAILED (%0d)", errors);
		$finish;
	end
end
endmodule
