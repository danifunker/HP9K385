//============================================================================
//  nereid — HP "Nereid" colormap of the 98550A.
//
//  512 x 24-bit entries: 0-255 video, $100-$103 overlay.  Registers sit on
//  the low byte of each word at $566000-$5660FF (reg n at $566000 + 2n + 1).
//  Reference: MAME video/nereid.cpp.
//
//    $01 BUSY (reads 0)         $50 ?   (stored)        $51 OVERLAY_CTL
//    $58 INDEX0                 $59/$5A/$5B RED/GREEN/BLUE
//    $5C INDEX (stored inverted) $5D PLANE_MASK         $5E OVERLAY_INDEX
//    $5F REV (=1)               $78 WRITE_STROBE        $7C READ_STROBE
//
//  Write strobe: entry INDEX (or $100 | OVERLAY_INDEX[2:1] when
//  OVERLAY_INDEX bit 3 is set) <= {R,G,B}.  Read strobe: {R,G,B} <= entry
//  INDEX.  Pixel lookup (pix_*): ovl &= OVERLAY_CTL; ovl != 0 ? pen[$100 |
//  (ovl & PLANE_MASK)] : pen[video & PLANE_MASK]; one clock of latency.
//============================================================================

module nereid
(
	input             clk,
	input             reset,

	input             cs,
	input             we,
	input       [6:0] reg_word,
	input       [7:0] din,
	output reg [15:0] dout,

	// pixel lookup (scanout / sim snapshot)
	input       [7:0] pix_video,
	input       [7:0] pix_overlay,
	output reg [23:0] pix_rgb
);

reg [23:0] clut [0:511];
reg  [7:0] red, green, blue, index, plane_mask, overlay_ctl, unk_a0, overlay_index;

always @(*) begin
	case (reg_word)
	7'h01: dout = 16'h0000;
	7'h59: dout = {8'hFF, red};
	7'h5A: dout = {8'hFF, green};
	7'h5B: dout = {8'hFF, blue};
	7'h5C: dout = {8'hFF, ~index};
	7'h58: dout = {8'hFF, index};
	7'h51: dout = {8'hFF, overlay_ctl};
	7'h78: dout = 16'hFF00;
	7'h5D: dout = {8'hFF, plane_mask};
	7'h50: dout = {8'hFF, unk_a0};
	7'h5E: dout = {8'hFF, overlay_index};
	7'h5F: dout = 16'hFF01;
	default: dout = 16'hFFFF;
	endcase
end

wire [8:0] wr_entry = overlay_index[3] ? {7'b1000000, overlay_index[2:1]} : {1'b0, index};

always @(posedge clk) begin
	if (reset) begin
		red <= 0; green <= 0; blue <= 0; index <= 0; plane_mask <= 0;
		overlay_ctl <= 0; unk_a0 <= 0; overlay_index <= 0;
	end
	else if (cs && we) begin
		case (reg_word)
		7'h59: red   <= din;
		7'h5A: green <= din;
		7'h5B: blue  <= din;
		7'h5C: index <= ~din;
		7'h58: index <= din;
		7'h78: clut[wr_entry] <= {red, green, blue};
		7'h7C: {red, green, blue} <= clut[{1'b0, index}];
		7'h5D: plane_mask    <= din;
		7'h51: overlay_ctl   <= din;
		7'h50: unk_a0        <= din;
		7'h5E: overlay_index <= din;
		default: ;
		endcase
	end
end

wire [7:0] ovl = pix_overlay & overlay_ctl;
always @(posedge clk)
	pix_rgb <= clut[ovl != 0 ? {1'b1, ovl & plane_mask} : {1'b0, pix_video & plane_mask}];

endmodule
