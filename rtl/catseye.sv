//============================================================================
//  catseye — HP 98550A "Catseye" frame-buffer controller (all 8 planes).
//
//  The card carries eight identical Catseye ASICs, one per bit plane.
//  Every one sees every write, and reads are ORed.  Plane n acts on
//  register writes whose enable bit 8+n is set.  This module is all eight
//  collapsed into one byte-wide engine:
//    - per-plane enables (FBEN, TCWEN, IE, ...) become 8-bit masks;
//    - the replacement rules (PRR, WRR) are kept per plane, because software
//      programs a colour by giving each plane its own rule;
//    - the other per-plane registers (TRR, VB, ACNTL, ...) are kept once,
//      written when any write-enabled plane takes them.
//  Reference: MAME video/catseye.cpp (Sven Schnelle), minus its known gaps:
//  the interrupt is not lost for plane 0, and VBLANK_INTRQ clears on write.
//
//  VRAM: 2048 x 1024 bytes per bank, 1 byte = 1 pixel, bit n = plane n.
//  Bank 0 = video, bank 1 = overlay.  It lives outside this module, behind
//  the vr_* port (longword address {bank, y[9:0], x[10:2]}).
//
//  Implemented: host pixel writes through PRR (word mode), window move with
//  WRR, clipping, source plane select, the TRR=$F0 pattern fill, STATUS,
//  VBLANK and window-move interrupts.
//  Not yet: RUG line drawing, bit mode (ACNTL $100), blink.  They set
//  `unsupported` so the sim can flag them.
//
//  Ports:
//    reg_*  16-bit register access, word index (byte offset >> 1) within
//           $564000-$5648FF; one access per reg_cs; dout combinational.
//    cpu_*  host VRAM longword access ($200000-$3FFFFF): held req, ack pulse.
//============================================================================

module catseye
#(
	parameter FRAME_CLKS = 549_634,     // 33 MHz / 60.04 Hz
	parameter VBL_CLKS   = 21_654       // 42 of 1066 lines
)
(
	input             clk,
	input             reset,
	input             card_reset,       // write to $560001: registers to defaults

	input             reg_cs,
	input             reg_we,
	input      [10:0] reg_word,
	input       [1:0] reg_be,           // [1] = D15:8, [0] = D7:0
	input      [15:0] reg_din,
	output reg [15:0] reg_dout,

	input             cpu_req,
	input             cpu_we,
	input      [20:2] cpu_addr,
	input       [3:0] cpu_be,
	input      [31:0] cpu_wdata,
	output reg        cpu_ack,
	output reg [31:0] cpu_rdata,

	output reg        vr_req,
	output reg        vr_we,
	output reg [21:2] vr_addr,
	output reg  [3:0] vr_be,
	output reg [31:0] vr_wdata,
	input             vr_ack,
	input      [31:0] vr_rdata,

	output            irq,
	output reg        in_vblank,
	output reg  [7:0] display_enable,
	output            busy,
	output reg        unsupported
);

//----------------------------------------------------------------------------
// Registers
//----------------------------------------------------------------------------
reg  [7:0] blink_en, sync_en, wm_ie, vbl_ie, wm_pend, vbl_pend;
reg  [7:0] fben   [0:1];
reg  [7:0] tcwen  [0:1];
reg  [7:0] tcren  [0:1];
reg [15:0] prr    [0:1][0:7];
reg [15:0] wrr    [0:1][0:7];
reg [15:0] trr    [0:1];
reg [15:0] trrctl [0:1];
reg [15:0] color  [0:1];
reg [15:0] vb     [0:1];
reg [15:0] planemode [0:1];
reg [15:0] acntl;
reg [15:0] misc, rugsc, wmx, linepath, linetype;
reg [15:0] wm_w, wm_h, wm_sx, wm_sy, wm_dx, wm_dy;
reg [15:0] clip_l, clip_r, clip_t, clip_b;
reg [15:0] status;
// Pattern RAM: per plane p, 32 words {bank, row}; host word $200/$300 + 16p + row.
// Eight small RAMs read asynchronously (MLABs), see the generate block below.
wire [15:0] pat_host_q;                       // host read data
wire        pat_host = (reg_word[10:7] == 4'b0100) || (reg_word[10:7] == 4'b0110);

function [15:0] combine;
	input [15:0] old, nw;
	input  [1:0] be;
	combine = {be[1] ? nw[15:8] : old[15:8], be[0] ? nw[7:0] : old[7:0]};
endfunction

// OR, over the planes whose read enable is clear, of a per-plane register
function [15:0] or_planes;
	input [127:0] v;      // 8 x 16
	input   [7:0] ren;
	integer n;
	begin
		or_planes = 16'd0;
		for (n = 0; n < 8; n = n + 1)
			if (!ren[n]) or_planes = or_planes | v[n*16 +: 16];
	end
endfunction

wire [127:0] prr0_v = {prr[0][7], prr[0][6], prr[0][5], prr[0][4], prr[0][3], prr[0][2], prr[0][1], prr[0][0]};
wire [127:0] prr1_v = {prr[1][7], prr[1][6], prr[1][5], prr[1][4], prr[1][3], prr[1][2], prr[1][1], prr[1][0]};
wire [127:0] wrr0_v = {wrr[0][7], wrr[0][6], wrr[0][5], wrr[0][4], wrr[0][3], wrr[0][2], wrr[0][1], wrr[0][0]};
wire [127:0] wrr1_v = {wrr[1][7], wrr[1][6], wrr[1][5], wrr[1][4], wrr[1][3], wrr[1][2], wrr[1][1], wrr[1][0]};

wire wm_busy;
assign busy = wm_busy;

always @(*) begin
	reg_dout = 16'h0000;
	if (pat_host) reg_dout = pat_host_q;
	else case (reg_word)
	11'h020: reg_dout = in_vblank ? 16'hFF00 : 16'h0000;
	11'h022: reg_dout = wm_busy ? {fben[0], 8'h00} : 16'h0000;
	11'h024: reg_dout = {vbl_pend, 8'h00};
	11'h026: reg_dout = {wm_pend, 8'h00};
	11'h040: reg_dout = {display_enable, 8'h00};
	11'h042: reg_dout = {sync_en, 8'h00};
	11'h044, 11'h284: reg_dout = {tcwen[0], 8'h00};
	11'h046, 11'h282: reg_dout = {8'h00, tcren[0]};
	11'h048, 11'h280: reg_dout = {fben[0], 8'h00};
	11'h04A: reg_dout = {wm_ie, 8'h00};
	11'h04C: reg_dout = {vbl_ie, 8'h00};
	11'h050: reg_dout = {blink_en, 8'h00};
	11'h075, 11'h281: reg_dout = or_planes(prr0_v, tcren[0]);
	11'h077, 11'h283: reg_dout = or_planes(wrr0_v, tcren[0]);
	11'h079, 11'h108, 11'h188: reg_dout = wm_sx;
	11'h07B, 11'h109, 11'h189: reg_dout = wm_sy;
	11'h07D, 11'h10A, 11'h18A: reg_dout = wm_dx;
	11'h07F, 11'h10B, 11'h18B: reg_dout = wm_dy;
	11'h081, 11'h104, 11'h184: reg_dout = wm_w;
	11'h083, 11'h105, 11'h185: reg_dout = wm_h;
	11'h102: reg_dout = misc;
	11'h103: reg_dout = rugsc;
	11'h106: reg_dout = linepath;
	11'h107: reg_dout = linetype;
	11'h10C: reg_dout = clip_l;
	11'h10D: reg_dout = clip_r;
	11'h10E: reg_dout = clip_t;
	11'h10F: reg_dout = clip_b;
	11'h285, 11'h385: reg_dout = 16'h0100;      // BARC rev
	11'h286: reg_dout = tcren[0] == 8'hFF ? 16'h0 : trr[0];
	11'h287: reg_dout = tcren[0] == 8'hFF ? 16'h0 : color[0];
	11'h288: reg_dout = tcren[0] == 8'hFF ? 16'h0 : vb[0];
	11'h289: reg_dout = tcren[0] == 8'hFF ? 16'h0 : trrctl[0];
	11'h28A: reg_dout = tcren[0] == 8'hFF ? 16'h0 : acntl;
	11'h28B: reg_dout = tcren[0] == 8'hFF ? 16'h0 : planemode[0];
	11'h380: reg_dout = {fben[1], 8'h00};
	11'h381: reg_dout = or_planes(prr1_v, tcren[1]);
	11'h382: reg_dout = {tcren[1], 8'h00};
	11'h383: reg_dout = or_planes(wrr1_v, tcren[1]);
	11'h384: reg_dout = {tcwen[1], 8'h00};
	11'h386: reg_dout = tcren[1] == 8'hFF ? 16'h0 : trr[1];
	11'h387: reg_dout = tcren[1] == 8'hFF ? 16'h0 : color[1];
	11'h388: reg_dout = tcren[1] == 8'hFF ? 16'h0 : vb[1];
	11'h389: reg_dout = tcren[1] == 8'hFF ? 16'h0 : trrctl[1];
	11'h38A: reg_dout = tcren[1] == 8'hFF ? 16'h0 : acntl;
	11'h38B: reg_dout = tcren[1] == 8'hFF ? 16'h0 : planemode[1];
	// STATUS: ready, no daughterboard, sticky bits, live vblank
	11'h400: reg_dout = 16'h000A | (status & ~16'h0010) | (in_vblank ? 16'h0010 : 16'h0);
	default: reg_dout = 16'h0000;
	endcase
end

//----------------------------------------------------------------------------
// Video timing stand-in: VBLANK at the 98550A's 60.04 Hz until real scanout
//----------------------------------------------------------------------------
reg [$clog2(FRAME_CLKS)-1:0] frame_cnt;
always @(posedge clk) begin
	if (reset) begin frame_cnt <= 0; in_vblank <= 0; end
	else begin
		frame_cnt <= (frame_cnt == FRAME_CLKS - 1) ? 0 : frame_cnt + 1'd1;
		in_vblank <= frame_cnt >= FRAME_CLKS - VBL_CLKS;
	end
end
wire vbl_rise = (frame_cnt == FRAME_CLKS - VBL_CLKS);

assign irq = |(wm_ie & wm_pend) || |(vbl_ie & vbl_pend);

//----------------------------------------------------------------------------
// Replacement rules: rule bit 3-{s,d} (0 clear, 3 source, 6 xor, 15 set...)
//----------------------------------------------------------------------------
function [7:0] apply_rules;
	input  [7:0] s, d, en;
	input [31:0] rules;       // 8 x 4
	integer n;
	reg [3:0] r;
	begin
		for (n = 0; n < 8; n = n + 1) begin
			r = rules[n*4 +: 4];
			apply_rules[n] = en[n] ? r[3 - {s[n], d[n]}] : d[n];
		end
	end
endfunction

function [31:0] host_rules;      // PRR bits 11:8 of each plane
	input bank;
	integer n;
	for (n = 0; n < 8; n = n + 1) host_rules[n*4 +: 4] = prr[bank][n][11:8];
endfunction

function [31:0] wm_rules;        // WRR bits 3:0 of each plane
	input bank;
	integer n;
	for (n = 0; n < 8; n = n + 1) wm_rules[n*4 +: 4] = wrr[bank][n][3:0];
endfunction

// does any enabled plane's rule read the source / the destination?
function uses_src;
	input [31:0] rules;
	input  [7:0] en;
	integer n;
	reg [3:0] r;
	begin
		uses_src = 0;
		for (n = 0; n < 8; n = n + 1) begin
			r = rules[n*4 +: 4];
			if (en[n] && r != 4'd0 && r != 4'd5 && r != 4'd10 && r != 4'd15) uses_src = 1;
		end
	end
endfunction

function uses_dst;
	input [31:0] rules;
	input  [7:0] en;
	integer n;
	reg [3:0] r;
	begin
		uses_dst = (en != 8'hFF);   // planes left alone must be preserved
		for (n = 0; n < 8; n = n + 1) begin
			r = rules[n*4 +: 4];
			if (en[n] && r != 4'd0 && r != 4'd3 && r != 4'd12 && r != 4'd15) uses_dst = 1;
		end
	end
endfunction

//----------------------------------------------------------------------------
// Register writes and the window-move trigger
//----------------------------------------------------------------------------
wire [15:0] d = reg_din;
wire        hi = reg_be[1];
reg         trig;            // T-register write: start a move on each FB-enabled bank
reg         trig_topcat;     // START_WMOVE: video bank only
integer     n;

always @(posedge clk) begin
	trig        <= 0;
	trig_topcat <= 0;
	if (reset || card_reset) begin
		blink_en <= 0; sync_en <= 0; wm_ie <= 0; vbl_ie <= 0;
		display_enable <= 8'hFF;
		fben[0] <= 0; fben[1] <= 0; tcwen[0] <= 0; tcwen[1] <= 0; tcren[0] <= 0; tcren[1] <= 0;
		for (n = 0; n < 8; n = n + 1) begin
			prr[0][n] <= 0; prr[1][n] <= 0; wrr[0][n] <= 0; wrr[1][n] <= 0;
		end
		trr[0] <= 0; trr[1] <= 0; trrctl[0] <= 0; trrctl[1] <= 0; color[0] <= 0; color[1] <= 0;
		vb[0] <= 0; vb[1] <= 0; planemode[0] <= 0; planemode[1] <= 0; acntl <= 0;
		misc <= 0; rugsc <= 0; wmx <= 0; linepath <= 0; linetype <= 0;
		wm_w <= 0; wm_h <= 0; wm_sx <= 0; wm_sy <= 0; wm_dx <= 0; wm_dy <= 0;
		clip_l <= 0; clip_r <= 0; clip_t <= 0; clip_b <= 0;
		if (reset) begin status <= 0; wm_pend <= 0; vbl_pend <= 0; end
	end
	else begin
		if (vbl_rise) vbl_pend <= vbl_pend | vbl_ie;
		if (wm_done) begin
			if (wm_done_topcat) wm_pend <= wm_pend | wm_ie;
			status <= status | 16'h0004;
		end
		if (cpu_wrote) status <= status | 16'h0004;

		if (reg_cs && reg_we) begin
			if (pat_host) ;                     // pattern RAM: written below
			else case (reg_word)
			11'h024: vbl_pend <= 0;
			11'h026: wm_pend <= 0;
			11'h040: if (hi) display_enable <= d[15:8];
			11'h042: if (hi) sync_en <= d[15:8];
			11'h044, 11'h284: if (hi) tcwen[0] <= d[15:8];
			11'h046, 11'h282: if (hi) tcren[0] <= d[7:0];
			11'h048, 11'h280: if (hi) fben[0] <= d[15:8];
			11'h04A: if (hi) wm_ie <= d[15:8];
			11'h04C: if (hi) vbl_ie <= d[15:8];
			11'h04E: if (|tcwen[0]) trig_topcat <= 1;
			11'h050: if (hi) blink_en <= d[15:8];
			11'h075, 11'h281: for (n = 0; n < 8; n = n + 1) if (tcwen[0][n]) prr[0][n] <= combine(prr[0][n], d, reg_be);
			11'h077, 11'h283: for (n = 0; n < 8; n = n + 1) if (tcwen[0][n]) wrr[0][n] <= combine(wrr[0][n], d, reg_be);
			11'h079, 11'h108: wm_sx <= combine(wm_sx, d, reg_be);
			11'h07B, 11'h109: wm_sy <= combine(wm_sy, d, reg_be);
			11'h07D, 11'h10A: wm_dx <= combine(wm_dx, d, reg_be);
			11'h07F, 11'h10B: wm_dy <= combine(wm_dy, d, reg_be);
			11'h081, 11'h104: wm_w  <= combine(wm_w,  d, reg_be);
			11'h083, 11'h105: wm_h  <= combine(wm_h,  d, reg_be);
			11'h100: begin
				wmx   <= combine(wmx,   d, reg_be);
				wm_sx <= combine(wm_sx, d, reg_be);
				wm_dx <= combine(wm_dx, d, reg_be);
			end
			11'h102: misc     <= combine(misc, d, reg_be);
			11'h103: rugsc    <= combine(rugsc, d, reg_be);
			11'h106: linepath <= combine(linepath, d, reg_be);
			11'h107: linetype <= combine(linetype, d, reg_be);
			11'h10C: clip_l   <= combine(clip_l, d, reg_be);
			11'h10D: clip_r   <= combine(clip_r, d, reg_be);
			11'h10E: clip_t   <= combine(clip_t, d, reg_be);
			11'h10F: clip_b   <= combine(clip_b, d, reg_be);
			11'h184: begin wm_w  <= combine(wm_w,  d, reg_be); trig <= 1; end
			11'h185: begin wm_h  <= combine(wm_h,  d, reg_be); trig <= 1; end
			11'h188: begin wm_sx <= combine(wm_sx, d, reg_be); trig <= 1; end
			11'h189: begin wm_sy <= combine(wm_sy, d, reg_be); trig <= 1; end
			11'h18A: begin wm_dx <= combine(wm_dx, d, reg_be); trig <= 1; end
			11'h18B: begin wm_dy <= combine(wm_dy, d, reg_be); trig <= 1; end
			11'h286: if (|tcwen[0]) trr[0]    <= combine(trr[0], d, reg_be);
			11'h287:                color[0]  <= combine(color[0], d, reg_be);
			11'h288: if (|tcwen[0]) vb[0]     <= combine(vb[0], d, reg_be);
			11'h289: if (|tcwen[0]) trrctl[0] <= combine(trrctl[0], d, reg_be);
			11'h28A: if (|tcwen[0]) acntl     <= combine(acntl, d, reg_be);
			11'h28B:                planemode[0] <= combine(planemode[0], d, reg_be);
			11'h380: if (hi) fben[1]  <= d[15:8];
			11'h381: for (n = 0; n < 8; n = n + 1) if (tcwen[1][n]) prr[1][n] <= combine(prr[1][n], d, reg_be);
			11'h382: if (hi) tcren[1] <= d[15:8];
			11'h383: for (n = 0; n < 8; n = n + 1) if (tcwen[1][n]) wrr[1][n] <= combine(wrr[1][n], d, reg_be);
			11'h384: if (hi) tcwen[1] <= d[15:8];
			11'h386: if (|tcwen[1]) trr[1]    <= combine(trr[1], d, reg_be);
			11'h387:                color[1]  <= combine(color[1], d, reg_be);
			11'h388: if (|tcwen[1]) vb[1]     <= combine(vb[1], d, reg_be);
			11'h389: if (|tcwen[1]) trrctl[1] <= combine(trrctl[1], d, reg_be);
			11'h38A: if (|tcwen[1]) acntl     <= combine(acntl, d, reg_be);
			11'h38B: if (|tcwen[1]) planemode[1] <= combine(planemode[1], d, reg_be);
			11'h400: status <= combine(status, d, reg_be);
			default: ;
			endcase
		end
	end
end

//----------------------------------------------------------------------------
// VRAM engine: host accesses and the window mover share the vr_* port
//
// The mover walks the rectangle in the overlap-safe order (bottom-up when
// the destination is below the source, right-to-left when it is right of
// it).  Each step handles a group: four pixels when they fill one aligned
// destination longword, sit at the same alignment in the source, and are
// all in_clip the clip rectangle; otherwise one pixel.  The destination
// longword is held in a write-back line (dc_*) and the source longword in a
// read line (sc_*), so a step whose data is present takes one clock and a
// full-screen clear costs one VRAM write per four pixels.
//----------------------------------------------------------------------------
localparam E_IDLE   = 3'd0;
localparam E_HREAD  = 3'd1;   // host: read the longword
localparam E_HWRITE = 3'd2;   // host: write it back (per bank)
localparam E_PIX    = 3'd3;   // mover: next group
localparam E_SRC    = 3'd4;   // mover: source longword read in flight
localparam E_FLUSH  = 3'd5;   // mover: destination line write-back in flight
localparam E_DST    = 3'd6;   // mover: destination longword read in flight
localparam E_END    = 3'd7;   // mover: final write-back, next bank

reg   [2:0] es;
reg         h_bank;           // host write: bank being written
reg  [31:0] h_old;
reg         cpu_wrote;

// mover state
reg         m_bank;
reg  [11:0] m_col, m_line;     // current offsets into the rectangle
reg         m_left, m_up;      // iterate right-to-left / bottom-to-top
reg         m_need_src, m_need_dst, m_pat;
reg  [31:0] m_rules;
reg   [7:0] m_en;
reg         m_srcsel;          // planemode: take one plane from a bank
reg   [3:0] m_srcplane;
// one-line caches
reg  [21:2] sc_tag;  reg sc_v;  reg [31:0] sc_data;
reg  [21:2] dc_tag;  reg dc_v;  reg [31:0] dc_data; reg [3:0] dc_valid, dc_dirty;
reg         wm_done, wm_done_topcat;
reg         pend_bank1;        // a T-trigger with both banks enabled

assign wm_busy = (es >= E_PIX);

wire [11:0] sx = wm_sx[11:0] + m_col;
wire [11:0] sy = wm_sy[11:0] + m_line;
wire [11:0] dx = wm_dx[11:0] + m_col;
wire [11:0] dy = wm_dy[11:0] + m_line;

function in_clip;
	input [11:0] x, y;
	in_clip = !misc[7] ||
	         !($signed({4'b0, y}) < $signed(clip_t) || $signed({4'b0, y}) > $signed(clip_b) ||
	           $signed({4'b0, x}) < $signed(clip_l) || $signed({4'b0, x}) > $signed(clip_r));
endfunction

// group of four: the aligned destination longword around dx
wire [11:0] gx0   = {dx[11:2], 2'b00};               // leftmost pixel of the longword
wire        g4    = (m_left ? (dx[1:0] == 2'd3 && m_col >= 12'd3)
                            : (dx[1:0] == 2'd0 && m_col + 12'd3 < wm_w[11:0])) &&
                    (!m_need_src || m_pat || sx[1:0] == dx[1:0]) &&
                    in_clip(gx0, dy) && in_clip(gx0 + 12'd3, dy);
wire        clipped = !g4 && !in_clip(dx, dy);
wire  [3:0] g_lanes = g4 ? 4'hF : (4'b0001 << (2'd3 - dx[1:0]));   // lane 3 = byte 0
wire        src_bank = m_srcsel ? m_srcplane[3] : m_bank;
wire [21:2] s_la = {src_bank, sy[9:0], sx[10:2]};
wire [21:2] d_la = {m_bank, dy[9:0], dx[10:2]};
// pixel at x = gx0 + i sits in lane 3-i; for one pixel the source byte
// moves from lane 3-sx[1:0] to lane 3-dx[1:0]
wire [31:0] s_word = g4 ? sc_data : ({24'd0, sc_data[(2'd3 - sx[1:0])*8 +: 8]} << ((2'd3 - dx[1:0]) * 8));

// source as the rules see it: whole bytes, or one plane replicated
function [7:0] src_view;
	input [7:0] b;
	src_view = m_srcsel ? {8{b[m_srcplane[2:0]]}} : b;
endfunction

// pattern bytes for the four pixels of the destination longword
// One RAM per plane.  The mover reads row dy of all eight at once; the host
// uses the read port when the mover is idle (a host read of a pattern
// register during a window move returns the mover's row).
wire [15:0] pat_q [0:7];
wire        pat_we   = reg_cs && reg_we && pat_host && |tcwen[reg_word[8]];
wire  [4:0] pat_ha   = {reg_word[8], reg_word[3:0]};
genvar gl, gp;
generate for (gp = 0; gp < 8; gp = gp + 1) begin : g_patram
	// high and low bytes apart, so a byte write needs no read-modify-write.
	// Separate modules: Quartus 17 won't infer a RAM declared in a generate.
	wire [4:0] ra = wm_busy ? {m_bank, dy[3:0]} : pat_ha;
	wire       pw = pat_we && reg_word[6:4] == gp;
	catseye_patram u_hi(.clk(clk), .we(pw && reg_be[1]), .wa(pat_ha), .d(reg_din[15:8]), .ra(ra), .q(pat_q[gp][15:8]));
	catseye_patram u_lo(.clk(clk), .we(pw && reg_be[0]), .wa(pat_ha), .d(reg_din[7:0]),  .ra(ra), .q(pat_q[gp][7:0]));
end endgenerate
assign pat_host_q = pat_q[reg_word[6:4]];

wire [31:0] pat_word;
generate for (gl = 0; gl < 4; gl = gl + 1) begin : g_lane
	for (gp = 0; gp < 8; gp = gp + 1) begin : g_plane
		assign pat_word[gl*8 + gp] = pat_q[gp][{dx[3:2], 2'd3 - gl[1:0]}];
	end
end endgenerate

wire [31:0] op_word;
generate for (gl = 0; gl < 4; gl = gl + 1) begin : g_op
	assign op_word[gl*8 +: 8] = apply_rules(m_pat ? pat_word[gl*8 +: 8] : src_view(s_word[gl*8 +: 8]),
	                                        dc_data[gl*8 +: 8], m_en,
	                                        m_pat ? {8{4'd3}} : m_rules);
end endgenerate

// what this step still lacks
wire        src_line_dirty = dc_v && dc_tag == s_la && |dc_dirty;   // flush before reading it
wire        src_ok = !m_need_src || m_pat || (sc_v && sc_tag == s_la && !src_line_dirty);
wire        dst_hit = dc_v && dc_tag == d_la;
wire        dst_ok  = dst_hit && (!m_need_dst || (dc_valid & g_lanes) == g_lanes);
wire        row_end = m_left ? (m_col < (g4 ? 12'd4 : 12'd1)) : (m_col + (g4 ? 12'd4 : 12'd1) >= wm_w[11:0]);

// start conditions
wire        bank1_only = (fben[0] == 0);
wire        start_t    = trig && (|fben[0] || |fben[1]);
wire        start_tc   = trig_topcat && |fben[0];

task automatic setup_move;
	input bank;
	begin
		m_bank     <= bank;
		m_up       <= wm_dy[11:0] > wm_sy[11:0];
		m_left     <= wm_dx[11:0] > wm_sx[11:0];
		m_line     <= (wm_dy[11:0] > wm_sy[11:0]) ? wm_h[11:0] - 12'd1 : 12'd0;
		m_col      <= (wm_dx[11:0] > wm_sx[11:0]) ? wm_w[11:0] - 12'd1 : 12'd0;
		m_pat      <= trrctl[bank][8];
		m_rules    <= wm_rules(bank);
		m_en       <= fben[bank];
		m_need_src <= !trrctl[bank][8] && uses_src(wm_rules(bank), fben[bank]);
		m_need_dst <= trrctl[bank][8] ? (fben[bank] != 8'hFF) : uses_dst(wm_rules(bank), fben[bank]);
		m_srcsel   <= planemode[bank][12];
		m_srcplane <= planemode[bank][11:8];
		sc_v <= 0; dc_v <= 0; dc_valid <= 0; dc_dirty <= 0;
	end
endtask

task automatic flush_dst;
	begin
		vr_req <= 1; vr_we <= 1; vr_be <= dc_dirty; vr_addr <= dc_tag; vr_wdata <= dc_data;
	end
endtask

always @(posedge clk) begin
	cpu_ack   <= 0;
	cpu_wrote <= 0;
	wm_done   <= 0;
	if (reset) begin
		es <= E_IDLE; vr_req <= 0; unsupported <= 0; pend_bank1 <= 0;
		sc_v <= 0; dc_v <= 0;
	end
	else case (es)
	E_IDLE: begin
		if (start_t || start_tc) begin
			wm_done_topcat <= start_tc;
			if (rugsc != 16'h0090 && !start_tc) begin
				// RUG line draw (VB vector, RUG_SC $10) is not implemented
				unsupported <= 1;
				wm_done     <= 1;
			end
			else if (wm_w != 0 && wm_h != 0) begin
				pend_bank1 <= start_t && |fben[0] && |fben[1];
				setup_move(start_tc ? 1'b0 : bank1_only);
				es <= E_PIX;
			end
			else
				wm_done <= 1;
		end
		else if (cpu_req && !cpu_ack) begin
			if (acntl[8]) unsupported <= 1;   // bit mode
			if (!cpu_we) begin
				vr_req  <= 1; vr_we <= 0; vr_be <= 4'hF;
				vr_addr <= {acntl[9], cpu_addr};
				es      <= E_HREAD;
			end
			else if (fben[0] == 0 && fben[1] == 0) begin
				cpu_ack <= 1;             // no plane takes the write
			end
			else begin
				h_bank  <= (fben[0] == 0);
				vr_req  <= 1; vr_we <= 0; vr_be <= 4'hF;
				vr_addr <= {fben[0] == 0, cpu_addr};
				es      <= E_HREAD;
			end
		end
	end
	E_HREAD: if (vr_ack) begin
		vr_req <= 0;
		if (!cpu_we) begin
			cpu_rdata <= vr_rdata;
			cpu_ack   <= 1;
			es        <= E_IDLE;
		end
		else begin
			h_old <= vr_rdata;
			es    <= E_HWRITE;
		end
	end
	E_HWRITE: begin
		if (!vr_req) begin
			vr_req   <= 1; vr_we <= 1; vr_be <= cpu_be;
			vr_addr  <= {h_bank, cpu_addr};
			vr_wdata <= {apply_rules(cpu_wdata[31:24], h_old[31:24], fben[h_bank], host_rules(h_bank)),
			             apply_rules(cpu_wdata[23:16], h_old[23:16], fben[h_bank], host_rules(h_bank)),
			             apply_rules(cpu_wdata[15:8],  h_old[15:8],  fben[h_bank], host_rules(h_bank)),
			             apply_rules(cpu_wdata[7:0],   h_old[7:0],   fben[h_bank], host_rules(h_bank))};
		end
		else if (vr_ack) begin
			vr_req    <= 0;
			cpu_wrote <= 1;
			if (!h_bank && fben[1] != 0) begin
				// the overlay bank takes the write too
				h_bank  <= 1;
				vr_req  <= 1; vr_we <= 0; vr_be <= 4'hF;
				vr_addr <= {1'b1, cpu_addr};
				es      <= E_HREAD;
			end
			else begin
				cpu_ack <= 1;
				es      <= E_IDLE;
			end
		end
	end

	// ---- window mover ----
	E_PIX: begin
		if (!clipped && m_need_src && src_line_dirty) begin
			flush_dst;
			es <= E_FLUSH;
		end
		else if (!clipped && !src_ok) begin
			vr_req <= 1; vr_we <= 0; vr_be <= 4'hF; vr_addr <= s_la;
			es <= E_SRC;
		end
		else if (!clipped && !dst_hit) begin
			if (dc_v && |dc_dirty) begin
				flush_dst;
				es <= E_FLUSH;
			end
			else begin
				dc_v <= 1; dc_tag <= d_la; dc_valid <= 0; dc_dirty <= 0;
				if (m_need_dst) begin
					vr_req <= 1; vr_we <= 0; vr_be <= 4'hF; vr_addr <= d_la;
					es <= E_DST;
				end
			end
		end
		else if (!clipped && !dst_ok) begin
			vr_req <= 1; vr_we <= 0; vr_be <= 4'hF; vr_addr <= d_la;
			es <= E_DST;
		end
		else begin
			// combine this group and step
			if (!clipped) begin
				dc_data  <= (dc_data & ~{{8{g_lanes[3]}}, {8{g_lanes[2]}}, {8{g_lanes[1]}}, {8{g_lanes[0]}}}) |
				            (op_word &  {{8{g_lanes[3]}}, {8{g_lanes[2]}}, {8{g_lanes[1]}}, {8{g_lanes[0]}}});
				dc_valid <= dc_valid | g_lanes;
				dc_dirty <= dc_dirty | g_lanes;
			end
			if (row_end) begin
				m_col <= m_left ? wm_w[11:0] - 12'd1 : 12'd0;
				if (m_up ? (m_line == 0) : (m_line == wm_h[11:0] - 12'd1))
					es <= E_END;
				else
					m_line <= m_up ? m_line - 12'd1 : m_line + 12'd1;
			end
			else
				m_col <= m_left ? m_col - (g4 ? 12'd4 : 12'd1) : m_col + (g4 ? 12'd4 : 12'd1);
		end
	end
	E_SRC: if (vr_ack) begin
		vr_req <= 0; sc_v <= 1; sc_tag <= s_la; sc_data <= vr_rdata;
		es <= E_PIX;
	end
	E_FLUSH: if (vr_ack) begin
		vr_req <= 0;
		if (sc_v && sc_tag == dc_tag) sc_v <= 0;   // keep the read line coherent
		dc_dirty <= 0;
		es <= E_PIX;
	end
	E_DST: if (vr_ack) begin
		vr_req <= 0;
		// bytes already combined into this line stay
		dc_data  <= {dc_dirty[3] ? dc_data[31:24] : vr_rdata[31:24],
		             dc_dirty[2] ? dc_data[23:16] : vr_rdata[23:16],
		             dc_dirty[1] ? dc_data[15:8]  : vr_rdata[15:8],
		             dc_dirty[0] ? dc_data[7:0]   : vr_rdata[7:0]};
		dc_valid <= 4'hF;
		es <= E_PIX;
	end
	E_END: begin
		if (vr_req) begin
			if (vr_ack) begin vr_req <= 0; dc_dirty <= 0; end
		end
		else if (dc_v && |dc_dirty)
			flush_dst;
		else if (pend_bank1) begin
			pend_bank1 <= 0;
			setup_move(1'b1);
			es <= E_PIX;
		end
		else begin
			dc_v <= 0; sc_v <= 0;
			wm_done <= 1;
			es <= E_IDLE;
		end
	end
	default: es <= E_IDLE;
	endcase
end

endmodule

// 32 x 8 MLAB, synchronous write, asynchronous read
module catseye_patram
(
	input        clk,
	input        we,
	input  [4:0] wa,
	input  [7:0] d,
	input  [4:0] ra,
	output [7:0] q
);
(* ramstyle = "MLAB, no_rw_check" *) reg [7:0] m [0:31];
assign q = m[ra];
always @(posedge clk) if (we) m[wa] <= d;
endmodule
