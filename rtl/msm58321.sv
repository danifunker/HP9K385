//============================================================================
//  msm58321 — OKI MSM58321 real-time clock behind the HP 300 8042.
//  Reference: MAME machine/msm58321.cpp; wiring from human_interface.cpp
//  (CS1 tied active, CS2 = latch bit 4, READ = latch bit 5, ADDRESS WRITE =
//  P2.1, WRITE = P2.2, D3..D0 = P1 3..0).
//
//  Registers (4-bit, BCD): 0 S1, 1 S10, 2 MI1, 3 MI10, 4 H1, 5 H10 (bit 3
//  24-hour, bit 2 PM in 12-hour mode), 6 W (day of week 0-6), 7 D1, 8 D10,
//  9 MO1, 10 MO10, 11 Y1, 12 Y10, 13 reset/busy (reads 0), 14/15 reference.
//  Strobes are level-sensitive: with CS2 high, ADDRESS WRITE latches the
//  address from D, WRITE stores D in the addressed register (writing a time
//  register also clears the sub-second count, as in MAME), READ drives the
//  register onto D (else D reads $F).
//
//  The clock keeps counting from a 1 Hz tick with the calendar (month
//  lengths, leap year when the BCD year is a multiple of 4).  It is set from
//  MiSTer's RTC (hps_io, MSM6242B byte layout) whenever that toggles, in
//  24-hour mode.
//============================================================================

module msm58321
#(
	parameter CLK_HZ = 33_000_000
)
(
	input            clk,
	input            reset,

	input            cs2,
	input            read,
	input            write,
	input            address_write,
	input      [3:0] din,
	output     [3:0] dout,

	input     [64:0] rtc_set          // hps_io RTC: bit 64 toggles on an update
);

reg  [3:0] r [0:12];
reg  [3:0] addr;
reg [$clog2(CLK_HZ)-1:0] div;
reg        set_t;

assign dout = !(cs2 && read) ? 4'hF :
              addr == 4'd13 ? 4'h0 :
              addr <= 4'd12 ? r[addr] : 4'hF;

// days in the current month (BCD month in r[10]:r[9], BCD year in r[12]:r[11])
wire [7:0] mo  = {r[10], r[9]};
wire [7:0] yr  = {r[12], r[11]};
wire       leap = ((yr[4] ^ yr[1]) == 1'b0) && !yr[0];    // BCD year divisible by 4
reg  [7:0] mdays;
always @(*) begin
	case (mo)
	8'h02:                      mdays = leap ? 8'h29 : 8'h28;
	8'h04, 8'h06, 8'h09, 8'h11: mdays = 8'h30;
	default:                    mdays = 8'h31;
	endcase
end

function [7:0] bcd_inc;               // two BCD digits + 1
	input [7:0] v;
	bcd_inc = (v[3:0] == 4'd9) ? {v[7:4] + 4'd1, 4'd0} : {v[7:4], v[3:0] + 4'd1};
endfunction

// The clock is battery-backed: a machine reset does not touch the time,
// only the power-up values below (2000-01-01 00:00:00, 24-hour mode).  The
// MiSTer sends its time once, while the core is still held in reset for
// the ROM download; set_t is not reset either, so that toggle is applied
// as soon as reset ends (it used to be swallowed, and every OS saw
// 1 January 2000: HP-UX "bad date in real-time clock", NetBSD "clock lost
// 7897 days").
integer i;
initial begin
	for (i = 0; i <= 12; i = i + 1) r[i] = 4'd0;
	r[5] = 4'h8;
	r[7] = 4'd1; r[9] = 4'd1;
	set_t = 1'b0;
end

always @(posedge clk) begin
	if (reset) begin
		addr <= 0; div <= 0;
	end
	else begin
		div <= (div == CLK_HZ - 1) ? '0 : div + 1'd1;

		// one second
		if (div == CLK_HZ - 1) begin
			if ({r[1], r[0]} != 8'h59) {r[1], r[0]} <= bcd_inc({r[1], r[0]});
			else begin
				{r[1], r[0]} <= 8'h00;
				if ({r[3], r[2]} != 8'h59) {r[3], r[2]} <= bcd_inc({r[3], r[2]});
				else begin
					{r[3], r[2]} <= 8'h00;
					// hours: 24-hour 00-23, 12-hour 12,1..11 with PM in H10 bit 2
					if (r[5][3]) begin
						if ({r[5][1:0], r[4]} != 6'h23) {r[5][1:0], r[4]} <= bcd_inc({2'b00, r[5][1:0], r[4]});
						else begin {r[5][1:0], r[4]} <= 6'h00; next_day; end
					end
					else begin
						if ({r[5][1:0], r[4]} == 6'h12) {r[5][1:0], r[4]} <= 6'h01;
						else if ({r[5][1:0], r[4]} == 6'h11) begin
							{r[5][1:0], r[4]} <= 6'h12;
							r[5][2] <= !r[5][2];
							if (r[5][2]) next_day;
						end
						else {r[5][1:0], r[4]} <= bcd_inc({2'b00, r[5][1:0], r[4]});
					end
				end
			end
		end

		// host access through the 8042
		if (cs2 && address_write) addr <= din;
		if (cs2 && write && addr <= 4'd12) begin
			div <= 0;
			case (addr)
			4'd1, 4'd3: r[addr] <= din & 4'h7;
			4'd5:       r[addr] <= din[3] ? (din & 4'hB) : din;
			4'd6:       r[addr] <= din & 4'h7;
			4'd10:      r[addr] <= din & 4'h1;
			default:    r[addr] <= din;
			endcase
		end

		// set from the MiSTer RTC (24-hour)
		set_t <= rtc_set[64];
		if (set_t != rtc_set[64]) begin
			{r[1], r[0]}   <= rtc_set[7:0];
			{r[3], r[2]}   <= rtc_set[15:8];
			r[4]           <= rtc_set[19:16];
			r[5]           <= {2'b10, rtc_set[21:20]};
			{r[8], r[7]}   <= rtc_set[31:24];
			{r[10], r[9]}  <= rtc_set[39:32];
			{r[12], r[11]} <= rtc_set[47:40];
			r[6]           <= rtc_set[51:48];
			div            <= 0;
		end
	end
end

task automatic next_day;
	begin
		r[6] <= (r[6] == 4'd6) ? 4'd0 : r[6] + 4'd1;
		if ({r[8], r[7]} != mdays) {r[8], r[7]} <= bcd_inc({r[8], r[7]});
		else begin
			{r[8], r[7]} <= 8'h01;
			if (mo != 8'h12) {r[10], r[9]} <= bcd_inc(mo);
			else begin
				{r[10], r[9]} <= 8'h01;
				{r[12], r[11]} <= (yr == 8'h99) ? 8'h00 : bcd_inc(yr);
			end
		end
	end
endtask

endmodule
