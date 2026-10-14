//============================================================================
//  sn76494 — TI SN76494 sound generator (the HP 300 keyboard beeper).
//  Reference: MAME sound/sn76496.cpp (SN76494: no /8 prescaler, white-noise
//  taps 0x04/0x08, 16-bit shift register).  The HP human-interface card
//  clocks it at 333,333 Hz; the 8042 writes bytes through P1 / P2.7.
//
//  Writes: %1 cc t dddd  latch channel cc, t = 1 attenuation / 0 tone low
//          %0 x dddddd   tone high 6 bits for the latched tone channel
//  Channel 3 is noise: bits 1:0 rate (N/32, N/64, N/128, tone 2), bit 2
//  white (1) / periodic (0); a write resets the shift register.
//
//  Updates run at clock / 2 (STEP_DIV clk ticks).  Each tone flips when its
//  10-bit counter runs out, so f = clock / (4 N).  Output is the signed sum
//  of the four channels, each +-volume by its attenuation (2 dB steps,
//  15 = off).
//============================================================================

module sn76494
#(
	parameter STEP_DIV = 198              // 33 MHz / (333,333 Hz / 2)
)
(
	input             clk,
	input             reset,
	input             wr,
	input       [7:0] din,
	output reg signed [15:0] audio
);

reg  [9:0] period [0:2];
reg  [3:0] atten  [0:3];
reg  [9:0] cnt    [0:2];
reg [10:0] ncnt;
reg  [3:0] out;                          // channel output levels
reg  [2:0] nctl;
reg [15:0] lfsr;
reg  [1:0] latch_ch;
reg        latch_vol;
reg [$clog2(STEP_DIV)-1:0] div;

wire       step = (div == STEP_DIV - 1);
// noise clock period in updates: 32 / 64 / 128, or twice tone 2's
wire [10:0] noise_period = nctl[1:0] == 2'd3 ? {period[2], 1'b0} : 11'd32 << nctl[1:0];

// 2 dB steps, full scale 8191 per channel
function [12:0] vol;
	input [3:0] a;
	case (a)
	4'd0: vol = 13'd8191; 4'd1: vol = 13'd6506; 4'd2: vol = 13'd5168; 4'd3: vol = 13'd4105;
	4'd4: vol = 13'd3261; 4'd5: vol = 13'd2590; 4'd6: vol = 13'd2057; 4'd7: vol = 13'd1634;
	4'd8: vol = 13'd1298; 4'd9: vol = 13'd1031; 4'd10: vol = 13'd819; 4'd11: vol = 13'd650;
	4'd12: vol = 13'd516; 4'd13: vol = 13'd410;  4'd14: vol = 13'd326; default: vol = 13'd0;
	endcase
endfunction

integer i;
reg signed [15:0] sum;
always @(*) begin
	sum = 16'sd0;
	for (i = 0; i < 4; i = i + 1)
		sum = ((i == 3) ? lfsr[0] : out[i]) ? sum + $signed({3'b000, vol(atten[i])})
		                                    : sum - $signed({3'b000, vol(atten[i])});
end

always @(posedge clk) begin
	if (reset) begin
		for (i = 0; i < 3; i = i + 1) begin period[i] <= 0; cnt[i] <= 0; end
		for (i = 0; i < 4; i = i + 1) atten[i] <= 4'hF;
		ncnt <= 0; out <= 0; nctl <= 0; lfsr <= 16'h8000; latch_ch <= 0; latch_vol <= 0; div <= 0;
		audio <= 0;
	end
	else begin
		div   <= step ? '0 : div + 1'd1;
		audio <= sum;

		if (step) begin
			for (i = 0; i < 3; i = i + 1) begin
				if (cnt[i] <= 10'd1) begin
					cnt[i] <= (period[i] == 0) ? 10'd1023 : period[i];  // 0: longest period
					out[i] <= !out[i];
				end
				else cnt[i] <= cnt[i] - 10'd1;
			end
			if (ncnt <= 11'd1) begin
				ncnt <= noise_period;
				// shift on each rising edge of the noise clock (white: taps 0 and 3)
				if (!out[3]) lfsr <= {nctl[2] ? (lfsr[0] ^ lfsr[3]) : lfsr[0], lfsr[15:1]};
				out[3] <= !out[3];
			end
			else ncnt <= ncnt - 11'd1;
		end

		if (wr) begin
			if (din[7]) begin
				latch_ch  <= din[6:5];
				latch_vol <= din[4];
				if (din[4]) atten[din[6:5]] <= din[3:0];
				else if (din[6:5] == 2'd3) begin nctl <= din[2:0]; lfsr <= 16'h8000; end
				else period[din[6:5]][3:0] <= din[3:0];
			end
			else if (!latch_vol) begin
				if (latch_ch == 2'd3) begin nctl <= din[2:0]; lfsr <= 16'h8000; end
				else period[latch_ch][9:4] <= din[5:0];
			end
			else atten[latch_ch] <= din[3:0];
		end
	end
end

endmodule
