//============================================================================
//  hil_dev — one HP-HIL device on the loop, high-level emulation after MAME
//  bus/hp_hil/hlebase.cpp, hlekbd.cpp (46021A ITF keyboard, TYPE 0) and
//  hlemouse.cpp (46060B mouse, TYPE 1).
//
//  A frame arrives on `start` (12 bits: 11 command, 10:8 address, 7:0 data).
//  The device answers commands addressed to it or to address 0:
//    $00 IFC             $01 EPT (pass-through)    $02 ELB (leave it)
//    $03 IDD             $04 DSR (address 0)       $09-$0F ACF (take address
//    n-8, pass n+1 on)   $10-$1F POL (report, poll count added)   $FE DHR
//  Frames it sends to the MLC come out one per clock on out_stb/out_frame.
//  Then `done` pulses with the frame as it leaves (frame_out) and `pass`:
//  pass = 1 sends it on to the next device (pass-through, or DHR); pass = 0
//  means this device returns it to the MLC itself (the loop controller does
//  that).
//
//  Keyboard: key bytes (HIL keycodes, bit 0 = release) queue up 8 deep; a
//  poll reports a $40 header ("keycode set 1") and the queued bytes; IDD is
//  layout $DF (US), $04.
//  Mouse: relative motion accumulates (8-bit, saturating); a poll reports a
//  header ($02 motion | $40 buttons), X and Y when there was motion, then
//  button bytes ($80/$81 left down/up, $82/$83 right, $84/$85 middle); IDD is
//  $68, $12 (X and Y axes), $C2, $1E (resolution).
//============================================================================

module hil_dev
#(
	parameter TYPE = 0                    // 0 keyboard, 1 mouse
)
(
	input             clk,
	input             reset,

	input             start,
	input      [11:0] frame_in,
	output reg        out_stb,
	output reg [11:0] out_frame,
	output reg        done,
	output reg [11:0] frame_out,
	output reg        pass,

	// keyboard input
	input             key_stb,
	input       [7:0] key_code,
	// mouse input: one report per strobe
	input             mouse_stb,
	input signed [8:0] mouse_dx,          // right positive
	input signed [8:0] mouse_dy,          // up positive
	input       [2:0] mouse_btn           // {middle, right, left}
);

reg  [2:0] id;
reg        passthru;

// event queue (key bytes or button bytes), 8 deep
reg  [7:0] q [0:7];
reg  [2:0] q_rd, q_wr;
reg  [3:0] q_cnt;
reg  [2:0] btn_q;
reg signed [8:0] mx, my;                  // accumulated motion (saturated to 8 bits)
reg        flush;

// what goes into the queue this clock
reg        enq;
reg  [7:0] enq_byte;
always @(*) begin
	enq = 1'b0; enq_byte = 8'h00;
	if (TYPE == 0) begin
		enq = key_stb; enq_byte = key_code;
	end
	else if (mouse_stb && mouse_btn != btn_q) begin
		// one button change per report is the normal case; report the
		// lowest changed button (left, right, middle)
		enq = 1'b1;
		if (mouse_btn[0] != btn_q[0])      enq_byte = mouse_btn[0] ? 8'h80 : 8'h81;
		else if (mouse_btn[1] != btn_q[1]) enq_byte = mouse_btn[1] ? 8'h82 : 8'h83;
		else                               enq_byte = mouse_btn[2] ? 8'h84 : 8'h85;
	end
end

localparam P_IDLE = 3'd0, P_HDR = 3'd1, P_X = 3'd2, P_Y = 3'd3, P_Q = 3'd4,
           P_IDD = 3'd5, P_DONE = 3'd6;
reg  [2:0] ps;
reg  [1:0] idd_n;
reg  [3:0] poll_left;
reg        motion;                        // this poll reports motion
reg [11:0] f;

wire       cmd   = frame_in[11];
wire [7:0] data  = frame_in[7:0];
wire       for_me = cmd && (frame_in[10:8] == 3'd0 || frame_in[10:8] == id);
wire       deq   = (ps == P_Q);

function signed [8:0] sat8;
	input signed [9:0] v;
	sat8 = (v > 10'sd127) ? 9'sd127 : (v < -10'sd128) ? -9'sd128 : v[8:0];
endfunction

wire [7:0] idd_byte = (TYPE == 0) ? (idd_n == 2'd0 ? 8'hDF : 8'h04)
                                  : (idd_n == 2'd0 ? 8'h68 : idd_n == 2'd1 ? 8'h12 :
                                     idd_n == 2'd2 ? 8'hC2 : 8'h1E);

always @(posedge clk) begin
	out_stb <= 1'b0;
	done    <= 1'b0;
	if (reset) begin
		id <= 0; passthru <= 0; q_rd <= 0; q_wr <= 0; q_cnt <= 0; btn_q <= 0;
		mx <= 0; my <= 0; ps <= P_IDLE; flush <= 0;
	end
	else begin
		// ---- inputs ----
		if (enq && (q_cnt != 4'd8 || deq)) begin q[q_wr] <= enq_byte; q_wr <= q_wr + 3'd1; end
		if (deq) q_rd <= q_rd + 3'd1;
		q_cnt <= flush ? 4'd0 : q_cnt + {3'd0, enq && (q_cnt != 4'd8 || deq)} - {3'd0, deq};
		flush <= 1'b0;
		// motion accumulates; the axis being reported this clock restarts
		// from whatever arrives with it
		if (TYPE == 1 && mouse_stb) btn_q <= mouse_btn;
		if (TYPE == 1) begin
			if (ps == P_X)      mx <= mouse_stb ? sat8(mouse_dx) : 9'sd0;
			else if (mouse_stb) mx <= sat8(mx + mouse_dx);
			if (ps == P_Y)      my <= mouse_stb ? sat8(mouse_dy) : 9'sd0;
			else if (mouse_stb) my <= sat8(my + mouse_dy);
		end

		// ---- a frame goes through ----
		case (ps)
		P_IDLE: if (start) begin
			f    <= frame_in;
			pass <= passthru;
			ps   <= P_DONE;
			if (for_me) begin
				casez (data)
				8'h01: begin passthru <= 1'b1; pass <= 1'b1; end            // EPT
				8'h02: begin passthru <= 1'b0; pass <= 1'b0; end            // ELB
				8'h03: begin idd_n <= 0; ps <= P_IDD; end                   // IDD
				8'h04: id <= 3'd0;                                          // DSR
				8'b0000_1???: if (data != 8'h08) begin                      // ACF
					id <= data[2:0];
					f  <= {frame_in[11:3], 3'd0} + {4'd0, data} - 12'd7;
				end
				8'b0001_????: begin                                         // POL
					motion    <= (TYPE == 1) && (mx != 0 || my != 0);
					poll_left <= q_cnt;
					if ((TYPE == 1 && (mx != 0 || my != 0)) || q_cnt != 0) begin
						ps <= P_HDR;
						f  <= frame_in + 12'd1 + ((TYPE == 1 && (mx != 0 || my != 0)) ? 12'd2 : 12'd0)
						      + {8'd0, q_cnt};
					end
				end
				8'hFE: begin                                                // DHR: reset, pass on
					passthru <= 1'b0; pass <= 1'b1;
					q_rd <= q_wr; flush <= 1'b1;
					if (TYPE == 1) begin mx <= 0; my <= 0; end
				end
				default: ;
				endcase
			end
		end
		P_HDR: begin
			out_stb   <= 1'b1;
			out_frame <= {1'b0, id, (TYPE == 0) ? 8'h40 : {1'b0, poll_left != 0, 4'b0000, motion, 1'b0}};
			ps        <= motion ? P_X : (poll_left != 0 ? P_Q : P_DONE);
		end
		P_X: begin
			out_stb <= 1'b1; out_frame <= {1'b0, id, mx[7:0]};
			ps <= P_Y;
		end
		P_Y: begin
			out_stb <= 1'b1; out_frame <= {1'b0, id, my[7:0]};
			ps <= (poll_left != 0) ? P_Q : P_DONE;
		end
		P_Q: begin
			out_stb <= 1'b1; out_frame <= {1'b0, id, q[q_rd]};
			poll_left <= poll_left - 4'd1;
			if (poll_left == 4'd1) ps <= P_DONE;
		end
		P_IDD: begin
			out_stb <= 1'b1; out_frame <= {1'b0, id, idd_byte};
			idd_n <= idd_n + 2'd1;
			if (idd_n == ((TYPE == 0) ? 2'd1 : 2'd3)) ps <= P_DONE;
		end
		P_DONE: begin
			done      <= 1'b1;
			frame_out <= f;
			ps        <= P_IDLE;
		end
		default: ps <= P_IDLE;
		endcase
	end
end

endmodule
