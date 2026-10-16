//============================================================================
//  scanout — the 98550A's display: both VRAM banks from DDR3, overlay over
//  video through the Nereid colormaps, as RGB video for the MiSTer scaler.
//
//  The MiSTer framebuffer can only scan one 8-bit buffer, but HP's X server
//  draws the pointer (and more) in the overlay bank, so the core scans out
//  itself.  1280 x 1024 visible at one pixel per clock (clk = clk_sys,
//  33 MHz): 1336 x 1030 total, about 24 Hz; the scaler makes 60 Hz of it.
//
//  Fetch: during line y the next line (y+1, or line 0 in vertical blank) is
//  read into the other half of a double-buffered line RAM, video bank then
//  overlay bank, in bursts of BURST 64-bit beats (8 pixels a beat, pixel
//  8k+i in byte i: the little-endian layout vram_ddr3 writes).  The fetch
//  port (f_*) is served by vram_ddr3 ahead of the CPU / mover traffic;
//  320 beats a line of 1336 clocks.
//
//  Pixel path: line RAM (1 clock), byte select, the Nereid lookup (1 clock,
//  pix_rgb), so sync and enable are delayed by 2.
//============================================================================

module scanout
#(
	parameter [28:0] BASE  = 29'h0600_0000,   // video bank, 64-bit word address
	parameter [28:0] OVL   = 29'h0604_0000,   // overlay bank (+2 MB)
	parameter        BURST = 32,
	parameter        HACT  = 1280, HFP = 8,  HSW = 32, HBP = 16,
	parameter        VACT  = 1024, VFP = 1,  VSW = 3,  VBP = 2
)
(
	input             clk,
	input             reset,

	// burst reads (vram_ddr3): hold f_req until f_ack; then BURST beats
	// arrive on f_valid / f_data
	output reg        f_req,
	output reg [28:0] f_addr,
	input             f_ack,
	input             f_valid,
	input      [63:0] f_data,

	// Nereid lookup (one clock)
	output reg  [7:0] pix_video,
	output reg  [7:0] pix_overlay,
	input      [23:0] pix_rgb,

	output reg        hs, vs, de,
	output     [23:0] rgb
);

localparam HTOT = HACT + HFP + HSW + HBP;
localparam VTOT = VACT + VFP + VSW + VBP;
localparam BEATS = HACT / 8;                  // 160 a bank a line
localparam NB    = BEATS / BURST;             // bursts a bank a line
localparam [8:0] BEATS9 = BEATS;
localparam [4:0] BLAST  = BURST - 1;          // BURST must be 32
localparam [2:0] NBLAST = NB - 1;

reg [11:0] hc;
reg [10:0] vc;
always @(posedge clk) begin
	if (reset) begin hc <= 0; vc <= 0; end
	else if (hc == HTOT - 1) begin
		hc <= 0;
		vc <= (vc == VTOT - 1) ? 11'd0 : vc + 11'd1;
	end
	else hc <= hc + 12'd1;
end

// ---- line fetch ---------------------------------------------------------
// fetch line fy into buffer half fy[0]; start at the beginning of each line
// for the next one (line 0 during the last blank line)
wire        line_start = (hc == 0);
wire [10:0] next_y     = (vc == VTOT - 1) ? 11'd0 : vc + 11'd1;
reg  [10:0] fy;
reg         fbank;                            // 0 video, 1 overlay
reg   [2:0] fburst;                           // burst within the bank
reg   [7:0] fbeat;                            // beats received this line+bank
reg         fbusy;

// line RAMs: 2 halves x 160 beats x 64 bits, video and overlay
(* ramstyle = "M10K" *) reg [63:0] lv [0:2 * BEATS - 1];
(* ramstyle = "M10K" *) reg [63:0] lo [0:2 * BEATS - 1];
wire [8:0] wslot = {1'b0, fbeat} + (fy[0] ? BEATS9 : 9'd0);

always @(posedge clk) begin
	if (reset) begin
		f_req <= 0; fbusy <= 0;
	end
	else begin
		if (line_start && next_y < VACT && !fbusy) begin
			fy     <= next_y;
			fbank  <= 0;
			fburst <= 0;
			fbeat  <= 0;
			fbusy  <= 1;
			f_req  <= 1;
			f_addr <= BASE + {11'd0, next_y[9:0], 8'd0};  // y * 2048 bytes = y * 256 words
		end
		if (f_req && f_ack) f_req <= 0;
		if (f_valid && fbusy) begin
			if (fbank) lo[wslot] <= f_data; else lv[wslot] <= f_data;
			fbeat <= fbeat + 8'd1;
			if (fbeat[4:0] == BLAST) begin
				// end of a burst: the next burst, the overlay bank, or done
				if (fburst != NBLAST) begin
					fburst <= fburst + 3'd1;
					f_req  <= 1;
					f_addr <= (fbank ? OVL : BASE) + {11'd0, fy[9:0], 8'd0} + {21'd0, fburst + 3'd1, 5'd0};
				end
				else if (!fbank) begin
					fbank  <= 1;
					fburst <= 0;
					fbeat  <= 0;
					f_req  <= 1;
					f_addr <= OVL + {11'd0, fy[9:0], 8'd0};
				end
				else fbusy <= 0;
			end
		end
	end
end

// ---- pixel path -----------------------------------------------------------
wire        act = (hc < HACT) && (vc < VACT);
wire  [8:0] rslot = {1'b0, hc[10:3]} + (vc[0] ? BEATS9 : 9'd0);
reg  [63:0] wv, wo;
reg   [2:0] sel;
reg         act1, act2, hs1, hs2, vs1, vs2;

always @(posedge clk) begin
	// stage 1: line RAM
	wv   <= lv[rslot];
	wo   <= lo[rslot];
	sel  <= hc[2:0];
	act1 <= act;
	hs1  <= (hc >= HACT + HFP) && (hc < HACT + HFP + HSW);
	vs1  <= (vc >= VACT + VFP) && (vc < VACT + VFP + VSW);
	// stage 2: byte select into the Nereid lookup
	pix_video   <= wv[sel * 8 +: 8];
	pix_overlay <= wo[sel * 8 +: 8];
	act2 <= act1; hs2 <= hs1; vs2 <= vs1;
	// stage 3: pix_rgb is valid
	de <= act2; hs <= hs2; vs <= vs2;
end

assign rgb = de ? pix_rgb : 24'd0;

endmodule
