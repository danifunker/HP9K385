//============================================================================
//  vram_ddr3 — the 98550A VRAM port (hp385_top vram_*) on MiSTer's DDR3.
//
//  VRAM bank 0 (video) and bank 1 (overlay) are 2 MB each at BASE and
//  BASE + 2 MB.  Pixel (x, y) of a bank is the byte at y * 2048 + x, so the
//  video bank can be scanned out directly by the MiSTer framebuffer
//  (FB_FORMAT 8 bpp indexed, FB_STRIDE 2048).
//
//  Byte order: the VRAM port is big-endian (be[3] / wdata[31:24] = byte +0),
//  DDR3 is little-endian (DDRAM_BE[0] / DIN[7:0] = byte +0), so every
//  longword is byte-reversed on the way through; A[2] picks the half of the
//  64-bit word.
//
//  Writes are posted: acknowledged as soon as DDR3 takes them (the Avalon
//  port keeps requests in order, so a later read sees them).  Reads hold the
//  request until DDRAM_DOUT_READY.  One request at a time.
//
//  Scanout fetch (f_*, rtl/scanout.sv): burst reads of FBURST beats, served
//  ahead of the VRAM port whenever the Avalon port is free; the beats come
//  back registered on f_valid / f_data.  VRAM requests wait meanwhile.
//
//  LAN mailbox (nb_*, rtl/lan_wire.sv): single 64-bit words at ARM physical
//  0x1FF0_0000 + 8 * nb_addr (Main's hp9k_enet bridge), after everything
//  else.  Writes are posted, reads held until the data returns.
//============================================================================

module vram_ddr3
#(
	parameter [28:0] BASE = 29'h0600_0000      // byte 0x3000_0000 >> 3
)
(
	input             clk,
	input             reset,

	input             req,
	input             we,
	input      [21:2] addr,
	input       [3:0] be,
	input      [31:0] wdata,
	output reg        ack,
	output reg [31:0] rdata,

	// scanout burst reads
	input             f_req,
	input      [28:0] f_addr,
	output reg        f_ack,
	output reg        f_valid,
	output reg [63:0] f_data,

	// LAN mailbox words
	input             nb_req,
	input             nb_we,
	input      [12:0] nb_addr,
	input      [63:0] nb_wdata,
	output reg        nb_ack,
	output reg [63:0] nb_rdata,

	input             DDRAM_BUSY,
	output reg  [7:0] DDRAM_BURSTCNT,
	output reg [28:0] DDRAM_ADDR,
	input      [63:0] DDRAM_DOUT,
	input             DDRAM_DOUT_READY,
	output reg        DDRAM_RD,
	output reg [63:0] DDRAM_DIN,
	output reg  [7:0] DDRAM_BE,
	output reg        DDRAM_WE
);

localparam [7:0]  FBURST  = 8'd32;
localparam [28:0] NB_BASE = 29'h03FE_0000;    // 0x1FF0_0000 >> 3

function [31:0] swap32;
	input [31:0] w;
	swap32 = {w[7:0], w[15:8], w[23:16], w[31:24]};
endfunction

wire [31:0] wd_le = swap32(wdata);
wire  [3:0] be_le = {be[0], be[1], be[2], be[3]};

reg busy_rd, busy_nb, half;
reg       fetching;
reg [7:0] f_left;

always @(posedge clk) begin
	ack     <= 1'b0;
	nb_ack  <= 1'b0;
	f_ack   <= 1'b0;
	f_valid <= 1'b0;
	if (reset) begin
		DDRAM_RD <= 0; DDRAM_WE <= 0; busy_rd <= 0; busy_nb <= 0; fetching <= 0;
		DDRAM_BURSTCNT <= 8'd1;
	end
	else begin
		if (!DDRAM_BUSY) begin
			DDRAM_RD <= 0;
			DDRAM_WE <= 0;
		end
		if (fetching) begin
			if (DDRAM_DOUT_READY) begin
				f_valid <= 1'b1;
				f_data  <= DDRAM_DOUT;
				f_left  <= f_left - 8'd1;
				if (f_left == 8'd1) fetching <= 0;
			end
		end
		else if (busy_rd) begin
			if (DDRAM_DOUT_READY) begin
				busy_rd <= 0;
				rdata   <= swap32(half ? DDRAM_DOUT[63:32] : DDRAM_DOUT[31:0]);
				ack     <= 1'b1;
			end
		end
		else if (busy_nb) begin
			if (DDRAM_DOUT_READY) begin
				busy_nb  <= 0;
				nb_rdata <= DDRAM_DOUT;
				nb_ack   <= 1'b1;
			end
		end
		else if (f_req && !f_ack && !DDRAM_BUSY && !(DDRAM_RD | DDRAM_WE)) begin
			// scanout first
			DDRAM_ADDR     <= f_addr;
			DDRAM_BURSTCNT <= FBURST;
			DDRAM_RD       <= 1'b1;
			f_ack          <= 1'b1;
			fetching       <= 1'b1;
			f_left         <= FBURST;
		end
		else if (req && !ack && !DDRAM_BUSY && !(DDRAM_RD | DDRAM_WE)) begin
			DDRAM_BURSTCNT <= 8'd1;
			DDRAM_ADDR <= BASE + {9'd0, addr[21:3]};
			half       <= addr[2];
			if (we) begin
				DDRAM_DIN <= {wd_le, wd_le};
				DDRAM_BE  <= addr[2] ? {be_le, 4'b0000} : {4'b0000, be_le};
				DDRAM_WE  <= 1'b1;
				ack       <= 1'b1;
			end
			else begin
				DDRAM_RD <= 1'b1;
				busy_rd  <= 1'b1;
			end
		end
		else if (nb_req && !nb_ack && !DDRAM_BUSY && !(DDRAM_RD | DDRAM_WE)) begin
			DDRAM_BURSTCNT <= 8'd1;
			DDRAM_ADDR     <= NB_BASE + {16'd0, nb_addr};
			if (nb_we) begin
				DDRAM_DIN <= nb_wdata;
				DDRAM_BE  <= 8'hFF;
				DDRAM_WE  <= 1'b1;
				nb_ack    <= 1'b1;
			end
			else begin
				DDRAM_RD <= 1'b1;
				busy_nb  <= 1'b1;
			end
		end
	end
end

endmodule
