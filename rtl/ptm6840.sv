//============================================================================
//  ptm6840 — Motorola MC6840 programmable timer module, HP 300 wiring.
//
//  HP 9000/3xx: E and C1/C3 all come from one 250 kHz oscillator, O3 feeds
//  C2 (timer 2 counts timer 3's output), gates are tied low (enabled), IRQ
//  goes to level 6.  The host sees the 8 registers on odd bytes at $5F8000.
//
//  Register map (rs):          write                 read
//    0                         CR1 (CR2[0]=1) / CR3   -- (0)
//    1                         CR2                    status
//    2 / 4 / 6                 MSB buffer             timer 1/2/3 counter MSB
//                                                     (LSB -> LSB buffer)
//    3 / 5 / 7                 timer 1/2/3 latch      LSB buffer
//                              {MSB buffer, data}
//
//  Control bits: 0 CR1 internal reset / CR2 register select / CR3 T3 /8
//  prescale; 1 internal clock (E); 2 dual 8-bit; 5:3 mode; 6 IRQ enable;
//  7 output enable.
//
//  Modes implemented: continuous (x0x0 with CRx3=0) in 16-bit and dual 8-bit,
//  and single-shot (CRx5=1).  The frequency/pulse-width comparison modes
//  (CRx3=1) need a gate input; with the gates tied low they count like
//  continuous mode here.  TODO if software is found that uses them.
//
//  Host port: one register access per cs pulse; dout is valid in the same
//  cycle (combinational) and side effects land on the clock edge.
//============================================================================

module ptm6840
#(
	parameter TICK_DIV = 132          // clk / 250 kHz (33 MHz / 132)
)
(
	input            clk,
	input            reset,

	input            cs,
	input            we,
	input      [2:0] rs,
	input      [7:0] din,
	output reg [7:0] dout,

	output           irq,
	output     [2:0] out              // O1..O3 pins (after output enable)
);

reg  [7:0] ctrl   [0:2];
reg [15:0] latch  [0:2];
reg [15:0] count  [0:2];
reg  [2:0] o;                 // internal output state
reg  [2:0] armed;             // single-shot: waiting for the first clock
reg  [2:0] flag;              // status bits 0-2
reg  [2:0] flag_seen;         // status read while the flag was set
reg  [7:0] msb_buf, lsb_buf;
reg  [2:0] t3_pre;

wire       held = ctrl[0][0]; // internal reset

assign out = o & {ctrl[2][7], ctrl[1][7], ctrl[0][7]};
wire       any_irq = |(flag & {ctrl[2][6], ctrl[1][6], ctrl[0][6]});
assign irq = any_irq;

// ---- 250 kHz E / C1 / C3 ----
reg  [$clog2(TICK_DIV)-1:0] div;
wire       e_tick = (div == TICK_DIV - 1);
always @(posedge clk) div <= (reset || e_tick) ? '0 : div + 1'd1;

// C2 = O3: timer 2 counts O3 falling edges
reg        o3_q;
always @(posedge clk) o3_q <= out[2];
wire       c2_tick = o3_q && !out[2];

// clock enables per timer (internal clock: E; external: C1, C2=O3, C3)
wire [2:0] src_tick = {e_tick,
                       ctrl[1][1] ? e_tick : c2_tick,
                       e_tick};
wire       t3_step = src_tick[2] && (!ctrl[2][0] || t3_pre == 3'd7);
wire [2:0] step = held ? 3'b000 : {t3_step, src_tick[1], src_tick[0]};

// ---- register read (combinational) ----
always @(*) begin
	case (rs)
	3'd0: dout = 8'h00;
	3'd1: dout = {any_irq, 4'b0000, flag};
	3'd2: dout = count[0][15:8];
	3'd4: dout = count[1][15:8];
	3'd6: dout = count[2][15:8];
	default: dout = lsb_buf;
	endcase
end

integer i;
reg [2:0] tmo;                        // timers timing out this clock (blocking temp)

always @(posedge clk) begin
	if (reset) begin
		ctrl[0] <= 8'h01; ctrl[1] <= 8'h00; ctrl[2] <= 8'h00;
		for (i = 0; i < 3; i = i + 1) begin
			latch[i] <= 16'hFFFF;
			count[i] <= 16'hFFFF;
		end
		o <= 0; armed <= 0; flag <= 0; flag_seen <= 0;
		msb_buf <= 0; lsb_buf <= 0; t3_pre <= 0;
	end
	else begin
		tmo = 3'b000;
		if (src_tick[2] && !held) t3_pre <= t3_pre + 1'd1;

		// ---- counting ----
		for (i = 0; i < 3; i = i + 1) begin
			if (held) begin
				count[i] <= latch[i];
				o[i]     <= 1'b0;
			end
			else if (step[i]) begin
				if (ctrl[i][2]) begin
					// dual 8-bit: output low for M*(L+1) clocks, high for L+1
					if (count[i][7:0] == 8'd0) begin
						if (count[i][15:8] == 8'd0) begin
							count[i] <= latch[i];
							o[i]     <= 1'b0;
							flag[i]  <= 1'b1; flag_seen[i] <= 1'b0; tmo[i] = 1'b1;
						end
						else begin
							count[i] <= {count[i][15:8] - 8'd1, latch[i][7:0]};
							if (count[i][15:8] == 8'd1) o[i] <= 1'b1;
						end
					end
					else
						count[i][7:0] <= count[i][7:0] - 8'd1;
				end
				else begin
					// 16-bit: time-out after latch+1 clocks
					if (count[i] == 16'd0) begin
						count[i] <= latch[i];
						flag[i]  <= 1'b1; flag_seen[i] <= 1'b0; tmo[i] = 1'b1;
						if (ctrl[i][5] && !ctrl[i][3]) o[i] <= 1'b0;   // single-shot ends
						else                           o[i] <= !o[i];
						armed[i] <= 1'b0;
					end
					else begin
						count[i] <= count[i] - 16'd1;
						if (armed[i]) begin o[i] <= 1'b1; armed[i] <= 1'b0; end
					end
				end
			end
		end

		// ---- host access (after counting, so it wins on the same edge) ----
		if (cs && we) begin
			case (rs)
			3'd0, 3'd1: begin
				if (rs == 3'd1) ctrl[1] <= din;
				else if (ctrl[1][0]) begin
					ctrl[0] <= din;
					// entering or leaving internal reset clears the flags
					if (din[0] != ctrl[0][0]) begin flag <= 0; flag_seen <= 0; end
					if (din[0] && !ctrl[0][0]) armed <= 0;
				end
				else ctrl[2] <= din;
			end
			3'd2, 3'd4, 3'd6: msb_buf <= din;
			default: begin   // 3, 5, 7: latch write
				latch[rs[2:1] - 2'd1] <= {msb_buf, din};
				flag[rs[2:1] - 2'd1]  <= 1'b0;
				if (!ctrl[rs[2:1] - 2'd1][4] || held) begin
					count[rs[2:1] - 2'd1] <= {msb_buf, din};
					o[rs[2:1] - 2'd1]     <= 1'b0;
					armed[rs[2:1] - 2'd1] <= ctrl[rs[2:1] - 2'd1][5];
				end
			end
			endcase
		end
		else if (cs) begin
			case (rs)
			3'd1: flag_seen <= flag_seen | flag;
			3'd2, 3'd4, 3'd6: begin
				lsb_buf <= count[rs[2:1] - 2'd1][7:0];
				// status read with the flag set, then counter read: clear
				// (not a time-out happening in this same clock)
				if (flag_seen[rs[2:1] - 2'd1] && !tmo[rs[2:1] - 2'd1]) begin
					flag[rs[2:1] - 2'd1]      <= 1'b0;
					flag_seen[rs[2:1] - 2'd1] <= 1'b0;
				end
			end
			default: ;
			endcase
		end
	end
end

endmodule
