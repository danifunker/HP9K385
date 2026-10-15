// Test fixture: the original register-file UPI-41 core (rtl/upi41.sv as of
// commit 8ed5143), renamed upi41_ref, for the lockstep test tb/tb_upi41_diff.sv.
// Do not edit; it is the reference behaviour of the block-RAM rewrite.
//============================================================================
//  upi41 — Intel UPI-41/42 (8042AH: 2 KB ROM, 256 B RAM) for the HP 300 HIL
//  controller.  Instruction semantics follow MAME's mcs48.cpp UPI-41 opcode
//  table, including its rule that an IBF interrupt taken right after a
//  JNIBF that saw IBF set returns to that jump's target.
//
//  Timing: one machine cycle = 15 oscillator clocks.  The core runs an
//  instruction in a few fast clocks, then waits out its 1 or 2 machine
//  cycles on `mc_tick` (one pulse per machine cycle: 333 kHz at 5 MHz), so
//  firmware delay loops and the timer keep real time.
//
//  Not implemented (unused by the HP 1820-4784 firmware or not wired on the
//  HP card): 8243 expander ops (MOVD/ANLD/ORLD execute as 2-cycle NOPs), DMA
//  handshake outputs, the event counter (T1 is tied high), external INT.
//
//  The ROM is a synchronous block RAM loaded through rom_wr/rom_addr/rom_data.
//============================================================================

module upi41_ref
(
	input             clk,
	input             reset,
	input             mc_tick,          // one pulse per machine cycle

	input             rom_wr,
	input      [10:0] rom_addr,
	input       [7:0] rom_data,

	// host (master) interface: A0 = 0 data, 1 command/status
	input             host_cs,
	input             host_we,
	input             host_a0,
	input       [7:0] host_din,
	output      [7:0] host_dout,

	input       [7:0] p1_in,
	output reg  [7:0] p1_out,
	input       [7:0] p2_in,
	output reg  [7:0] p2_out,
	input             t0,
	input             t1,

	output reg        p1_rd,            // IN A,P1 executed (read side effects)

	output reg [10:0] dbg_pc,           // address of the last dispatched opcode
	output reg        dbg_dispatch      // pulses once per instruction
);

//----------------------------------------------------------------------------
// Program ROM
//----------------------------------------------------------------------------
reg  [7:0] rom [0:2047];
reg [10:0] rom_ra;
reg  [7:0] rom_q;
always @(posedge clk) begin
	if (rom_wr) rom[rom_addr] <= rom_data;
	rom_q <= rom[rom_ra];
end

//----------------------------------------------------------------------------
// Architectural state
//----------------------------------------------------------------------------
reg  [7:0] ram [0:255];
reg [10:0] pc;
reg  [7:0] a, psw;                  // PSW: C AC F0 BS 1 SP2..0
reg        f1;
reg  [7:0] timer;
reg  [4:0] prescaler;
reg        timer_run, timer_flag, timer_ovf, tirq_en, xirq_en;
reg        flags_en, dma_en, irq_busy, irq_polled;
reg [10:0] polled_target;
reg  [7:0] sts, dbbi, dbbo;         // STS: 7:4 user, 1 IBF, 0 OBF
reg  [1:0] debt;                    // machine cycles still owed

wire [7:0] rbase = psw[4] ? 8'd24 : 8'd0;
function [7:0] radr; input [2:0] r; radr = rbase + {5'd0, r}; endfunction

assign host_dout = host_a0 ? {sts[7:4], f1, psw[5], sts[1:0]} : dbbo;

wire [7:0] p2_mask = ~((flags_en ? 8'h30 : 8'h00) | (dma_en ? 8'hC0 : 8'h00));

//----------------------------------------------------------------------------
// Decode helpers
//----------------------------------------------------------------------------
function two_byte;
	input [7:0] o;
	casez (o)
	8'h03, 8'h13, 8'h23, 8'h43, 8'h53, 8'hD3,             // ALU A,#n / MOV A,#n
	8'b???0_0100, 8'b???1_0100,                          // JMP, CALL
	8'b???1_0010,                                        // JBb
	8'h16, 8'h26, 8'h36, 8'h46, 8'h56, 8'h76, 8'h86, 8'h96,
	8'hB6, 8'hC6, 8'hD6, 8'hE6, 8'hF6,                   // Jcc
	8'b1110_1???,                                        // DJNZ
	8'b1011_1???, 8'hB0, 8'hB1,                          // MOV Rn,#n / MOV @Ri,#n
	8'h89, 8'h8A, 8'h99, 8'h9A:                          // ORL/ANL P1/P2,#n
		two_byte = 1;
	default: two_byte = 0;
	endcase
endfunction

function [1:0] cycles;
	input [7:0] o;
	casez (o)
	8'h09, 8'h0A, 8'h39, 8'h3A, 8'h83, 8'h93, 8'hA3, 8'hE3, 8'hB3,
	8'b0000_11??, 8'b0011_11??, 8'b1000_11??, 8'b1001_11??:
		cycles = 2'd2;
	default: cycles = two_byte(o) ? 2'd2 : 2'd1;
	endcase
endfunction

function [9:0] add8;           // {C, AC, sum}
	input [7:0] x, y;
	input       cin;
	reg   [8:0] t;
	reg   [4:0] t4;
	begin
		t  = {1'b0, x} + {1'b0, y} + {8'd0, cin};
		t4 = {1'b0, x[3:0]} + {1'b0, y[3:0]} + {4'd0, cin};
		add8 = {t[8], t4[4], t[7:0]};
	end
endfunction

//----------------------------------------------------------------------------
// Execution: FETCH -> OPWAIT -> DECODE -> (ARGWAIT) -> EXEC -> (PUSH2) -> WAIT
//----------------------------------------------------------------------------
localparam S_FETCH = 3'd0, S_OPWAIT = 3'd1, S_DECODE = 3'd2, S_ARGWAIT = 3'd3,
           S_EXEC = 3'd4, S_PUSH2 = 3'd5, S_WAIT = 3'd6;
reg  [2:0] st;
reg  [7:0] op;
reg  [3:0] argpage;            // PC page of the argument byte (Jcc target page)
reg [10:0] push_pc;
reg  [7:0] push_psw;

wire [7:0] rn  = ram[radr(op[2:0])];
wire [7:0] ri  = ram[radr({2'b00, op[0]})];
wire [7:0] ind = ram[ri];
wire [7:0] imm = rom_q;        // argument byte / MOVP data in S_EXEC
wire [10:0] jcc = {argpage[2:0], imm};

wire [2:0] sp_dn   = psw[2:0] - 3'd1;
wire [7:0] pull_lo = ram[8'd8 + {4'd0, sp_dn, 1'b0}];
wire [7:0] pull_hi = ram[8'd9 + {4'd0, sp_dn, 1'b0}];

// ADD/ADDC operand: register, @Ri or immediate; carry in for ADDC (x1_xxxx)
wire [7:0] add_src = (op == 8'h03 || op == 8'h13) ? imm : op[3] ? rn : ind;
wire [9:0] add_res = add8(a, add_src, op[4] & psw[7]);

// DA A
reg  [7:0] da_a;
reg        da_c;
always @(*) begin
	da_a = a; da_c = psw[7];
	if (a[3:0] > 4'd9 || psw[6]) begin
		if (a > 8'hF9) da_c = 1'b1;
		da_a = a + 8'h06;
	end
	if (da_a[7:4] > 4'd9 || da_c) begin
		da_a = da_a + 8'h60;
		da_c = 1'b1;
	end
end

wire take_x = !irq_busy && xirq_en && sts[1];
wire take_t = !irq_busy && !(xirq_en && sts[1]) && timer_ovf && tirq_en;

task automatic push_and_jump;
	input [10:0] ret_pc;
	input [10:0] target;
	begin
		ram[8'd8 + {4'd0, psw[2:0], 1'b0}] <= ret_pc[7:0];
		push_pc  <= ret_pc;
		push_psw <= psw;
		psw[2:0] <= psw[2:0] + 3'd1;
		pc       <= target;
		st       <= S_PUSH2;
	end
endtask

always @(posedge clk) begin
	dbg_dispatch <= 1'b0;
	p1_rd        <= 1'b0;
	if (reset) begin
		st <= S_FETCH;
		pc <= 0; psw <= psw & 8'hC0; f1 <= 0;
		tirq_en <= 0; xirq_en <= 0; timer_run <= 0; timer_flag <= 0; timer_ovf <= 0;
		sts <= 0; flags_en <= 0; dma_en <= 0; irq_busy <= 0; irq_polled <= 0;
		dbbo <= 8'hFF; p1_out <= 8'hFF; p2_out <= 8'hFF; debt <= 0; prescaler <= 0;
	end
	else begin
		// ---- host side of the data bus buffer (any time) ----
		if (host_cs && host_we) begin
			dbbi <= host_din;
			f1   <= host_a0;
			if (!sts[1]) begin
				sts[1] <= 1'b1;
				if (flags_en) p2_out[5] <= 1'b0;       // P2.5 = !IBF
			end
		end
		else if (host_cs && !host_a0 && sts[0]) begin
			sts[0] <= 1'b0;                           // reading data clears OBF
			if (flags_en) p2_out[4] <= 1'b0;          // P2.4 = OBF
		end

		// ---- machine cycles and the timer (prescaler /32) ----
		if (mc_tick && debt != 0) begin
			debt <= debt - 2'd1;
			if (timer_run) begin
				prescaler <= prescaler + 5'd1;
				if (prescaler == 5'd31) begin
					timer <= timer + 8'd1;
					if (timer == 8'hFF) begin
						timer_flag <= 1'b1;
						if (tirq_en) timer_ovf <= 1'b1;
					end
				end
			end
		end

		case (st)
		S_WAIT: if (debt == 0) st <= S_FETCH;

		S_FETCH: begin
			if (take_x || take_t) begin
				// CALL 3 (IBF) / CALL 7 (timer); 2 machine cycles
				irq_busy   <= 1'b1;
				irq_polled <= 1'b0;
				if (take_t) timer_ovf <= 1'b0;
				debt <= 2'd2;
				push_and_jump((take_x && irq_polled) ? polled_target : pc, take_x ? 11'h003 : 11'h007);
			end
			else begin
				rom_ra <= pc;
				dbg_pc <= pc;
				dbg_dispatch <= 1'b1;
				pc     <= pc + 11'd1;
				st     <= S_OPWAIT;
			end
		end
		S_OPWAIT: st <= S_DECODE;
		S_DECODE: begin
			op         <= rom_q;
			debt       <= cycles(rom_q);
			irq_polled <= 1'b0;
			argpage    <= {1'b0, pc[10:8]};
			if (two_byte(rom_q)) begin
				rom_ra <= pc;
				pc     <= pc + 11'd1;
				st     <= S_ARGWAIT;
			end
			else if (rom_q == 8'hA3 || rom_q == 8'hB3) begin   // MOVP / JMPP: same page
				rom_ra <= {pc[10:8], a};
				st     <= S_ARGWAIT;
			end
			else if (rom_q == 8'hE3) begin                      // MOVP3: page 3
				rom_ra <= {3'b011, a};
				st     <= S_ARGWAIT;
			end
			else st <= S_EXEC;
		end
		S_ARGWAIT: st <= S_EXEC;                 // block-RAM read latency
		S_EXEC: begin
			st <= S_WAIT;
			casez (op)
			// ---- arithmetic / logic ----
			8'b0110_1???: {psw[7], psw[6], a} <= add_res;
			8'b0110_000?: {psw[7], psw[6], a} <= add_res;
			8'h03:        {psw[7], psw[6], a} <= add_res;
			8'b0111_1???: {psw[7], psw[6], a} <= add_res;
			8'b0111_000?: {psw[7], psw[6], a} <= add_res;
			8'h13:        {psw[7], psw[6], a} <= add_res;
			8'b0101_1???: a <= a & rn;
			8'b0101_000?: a <= a & ind;
			8'h53:        a <= a & imm;
			8'b0100_1???: a <= a | rn;
			8'b0100_000?: a <= a | ind;
			8'h43:        a <= a | imm;
			8'b1101_1???: a <= a ^ rn;
			8'b1101_000?: a <= a ^ ind;
			8'hD3:        a <= a ^ imm;
			8'h27: a <= 8'h00;
			8'h37: a <= ~a;
			8'h17: a <= a + 8'd1;
			8'h07: a <= a - 8'd1;
			8'h57: begin a <= da_a; psw[7] <= da_c; end
			8'h47: a <= {a[3:0], a[7:4]};
			8'hE7: a <= {a[6:0], a[7]};
			8'hF7: begin a <= {a[6:0], psw[7]}; psw[7] <= a[7]; end
			8'h77: a <= {a[0], a[7:1]};
			8'h67: begin a <= {psw[7], a[7:1]}; psw[7] <= a[0]; end
			8'h97: psw[7] <= 1'b0;
			8'hA7: psw[7] <= ~psw[7];
			8'h85: psw[5] <= 1'b0;
			8'h95: psw[5] <= ~psw[5];
			8'hA5: f1 <= 1'b0;
			8'hB5: f1 <= ~f1;
			// ---- registers and data memory ----
			8'b0001_1???: ram[radr(op[2:0])] <= rn + 8'd1;
			8'b1100_1???: ram[radr(op[2:0])] <= rn - 8'd1;
			8'b0001_000?: ram[ri] <= ind + 8'd1;
			8'b1111_1???: a <= rn;
			8'b1111_000?: a <= ind;
			8'h23:        a <= imm;
			8'b1010_1???: ram[radr(op[2:0])] <= a;
			8'b1010_000?: ram[ri] <= a;
			8'b1011_1???: ram[radr(op[2:0])] <= imm;
			8'b1011_000?: ram[ri] <= imm;
			8'b0010_1???: begin a <= rn;  ram[radr(op[2:0])] <= a; end
			8'b0010_000?: begin a <= ind; ram[ri] <= a; end
			8'b0011_000?: begin a <= {a[7:4], ind[3:0]}; ram[ri] <= {ind[7:4], a[3:0]}; end
			8'hC7: a <= psw | 8'h08;
			8'hD7: psw <= a & 8'hF7;
			8'h42: a <= timer;
			8'h62: timer <= a;
			8'h90: sts[7:4] <= a[7:4];
			8'hC5: psw[4] <= 1'b0;                     // SEL RB0
			8'hD5: psw[4] <= 1'b1;                     // SEL RB1
			// ---- ports and the data bus buffer ----
			8'h09: begin a <= p1_in & p1_out; p1_rd <= 1'b1; end
			8'h0A: a <= p2_in & p2_out;
			8'h39: p1_out <= a;
			8'h3A: p2_out <= (p2_out & ~p2_mask) | (a & p2_mask);
			8'h89: p1_out <= p1_out | imm;
			8'h99: p1_out <= p1_out & imm;
			8'h8A: p2_out <= p2_out | (imm & p2_mask);
			8'h9A: p2_out <= p2_out & (imm | ~p2_mask);
			8'h22: begin                                // IN A,DBB
				a <= dbbi;
				if (!(host_cs && host_we)) begin
					sts[1] <= 1'b0;
					if (flags_en) p2_out[5] <= 1'b1;
				end
			end
			8'h02: begin                                // OUT DBB,A
				dbbo   <= a;
				sts[0] <= 1'b1;
				if (flags_en) p2_out[4] <= 1'b1;
			end
			8'hE5: dma_en   <= 1'b1;                   // EN DMA
			8'hF5: flags_en <= 1'b1;                   // EN FLAGS
			// ---- interrupts and the timer ----
			8'h05: xirq_en <= 1'b1;
			8'h15: xirq_en <= 1'b0;
			8'h25: tirq_en <= 1'b1;
			8'h35: begin tirq_en <= 1'b0; timer_ovf <= 1'b0; end
			8'h55: begin timer_run <= 1'b1; prescaler <= 5'd0; end   // STRT T
			8'h45: timer_run <= 1'b0;                  // STRT CNT (T1 never toggles)
			8'h65: timer_run <= 1'b0;                  // STOP TCNT
			// ---- control transfer ----
			8'b???0_0100: pc <= {op[7:5], imm};        // JMP
			8'b???1_0100: push_and_jump(pc, {op[7:5], imm});   // CALL
			8'h83: begin                                // RET
				pc <= {pull_hi[2:0], pull_lo};
				psw[2:0] <= sp_dn;
			end
			8'h93: begin                                // RETR
				irq_busy <= 1'b0;
				pc  <= {pull_hi[2:0], pull_lo};
				psw <= {pull_hi[7:4], 1'b0, sp_dn};
			end
			8'hB3: pc <= {pc[10:8], imm};               // JMPP @A
			8'hA3, 8'hE3: a <= imm;                     // MOVP / MOVP3
			8'b???1_0010: if (a[op[7:5]]) pc <= jcc;    // JBb
			8'h16: begin if (timer_flag) pc <= jcc; timer_flag <= 1'b0; end
			8'h26: if (!t0)     pc <= jcc;
			8'h36: if (t0)      pc <= jcc;
			8'h46: if (!t1)     pc <= jcc;
			8'h56: if (t1)      pc <= jcc;
			8'h76: if (f1)      pc <= jcc;
			8'h86: if (sts[0])  pc <= jcc;              // JOBF
			8'h96: if (a != 0)  pc <= jcc;
			8'hB6: if (psw[5])  pc <= jcc;
			8'hC6: if (a == 0)  pc <= jcc;
			8'hD6: begin                                // JNIBF
				irq_polled    <= sts[1];
				polled_target <= jcc;
				if (!sts[1]) pc <= jcc;
			end
			8'hE6: if (!psw[7]) pc <= jcc;
			8'hF6: if (psw[7])  pc <= jcc;
			8'b1110_1???: begin                         // DJNZ
				ram[radr(op[2:0])] <= rn - 8'd1;
				if (rn != 8'd1) pc <= jcc;
			end
			default: ;                                  // NOP, expander ops, illegal
			endcase
		end
		S_PUSH2: begin
			ram[8'd9 + {4'd0, push_psw[2:0], 1'b0}] <= {push_psw[7:4], 1'b0, push_pc[10:8]};
			st <= S_WAIT;
		end
		default: st <= S_FETCH;
		endcase
	end
end

endmodule
