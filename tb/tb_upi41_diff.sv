// Lockstep differential bench: rtl/upi41.sv (block-RAM data memory) against
// tb/upi41_ref.sv (the original register-file core), both running the real
// HIL firmware with identical stimulus.  Every clock it compares the ports
// (dbg_pc, dbg_dispatch, p1_out, p2_out, p1_rd, host_dout) and the common
// architectural / sequencer state; the whole data RAM is compared every
// 4096 clocks and at the end.
//
// Build and run from the repo root:
//   $ verilator --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_upi41_diff \
//     --Mdir build/obj_tb_upi41 -o tb tb/tb_upi41_diff.sv tb/upi41_ref.sv rtl/upi41.sv
//   $ build/obj_tb_upi41/tb [+rom=<1820-4784.bin>] [+cycles=N] [+seed=S] [+randrom]
//
// Phases: real machine-cycle ticks (every 99 clocks) for the first half,
// then random ticks (often back to back) so the cores are also compared
// with instructions running into each other; a few resets land at random
// points.  The host follows the HP boot ROM pattern (poll status, command,
// data, read results) mixed with random accesses of 1-3 clocks at any clock.
`timescale 1ns/1ps
module tb_upi41_diff;

reg clk = 0;
always #5 clk = !clk;

reg        reset = 1;
reg        mc_tick = 0;
reg        rom_wr = 0;
reg [10:0] rom_addr = 0;
reg  [7:0] rom_data = 0;
reg        host_cs = 0, host_we = 0, host_a0 = 0;
reg  [7:0] host_din = 0;
reg  [7:0] p1_in = 8'hFF, p2_in = 8'hDF;
reg        t0 = 1, t1 = 1;

wire [7:0] r_dout, d_dout, r_p1, d_p1, r_p2, d_p2;
wire       r_p1rd, d_p1rd, r_disp, d_disp;
wire [10:0] r_pc, d_pc;

upi41_ref ref_cpu (
	.clk(clk), .reset(reset), .mc_tick(mc_tick),
	.rom_wr(rom_wr), .rom_addr(rom_addr), .rom_data(rom_data),
	.host_cs(host_cs), .host_we(host_we), .host_a0(host_a0), .host_din(host_din),
	.host_dout(r_dout), .p1_in(p1_in), .p1_out(r_p1), .p2_in(p2_in), .p2_out(r_p2),
	.t0(t0), .t1(t1), .p1_rd(r_p1rd), .dbg_pc(r_pc), .dbg_dispatch(r_disp));

upi41 dut (
	.clk(clk), .reset(reset), .keep_dbb(1'b0), .mc_tick(mc_tick),
	.rom_wr(rom_wr), .rom_addr(rom_addr), .rom_data(rom_data),
	.host_cs(host_cs), .host_we(host_we), .host_a0(host_a0), .host_din(host_din),
	.host_dout(d_dout), .p1_in(p1_in), .p1_out(d_p1), .p2_in(p2_in), .p2_out(d_p2),
	.t0(t0), .t1(t1), .p1_rd(d_p1rd), .dbg_pc(d_pc), .dbg_dispatch(d_disp));

//----------------------------------------------------------------------------
// Settings
//----------------------------------------------------------------------------
reg [8*256-1:0] rom_file;
longint  cycles = 20000000;
int      seed = 1;
reg [7:0] img [0:2047];

longint  cyc = 0;
int      errors = 0;
bit      random_ticks = 0;
bit      running = 0;

// statistics
longint  n_disp = 0, n_irq_x = 0, n_irq_t = 0, n_hwr = 0, n_hrd = 0, n_resets = 0;
longint  n_ticks = 0;
bit      seen_op [0:255];
bit      seen_pc [0:2047];

//----------------------------------------------------------------------------
// Machine-cycle ticks
//----------------------------------------------------------------------------
reg [6:0] mc_div = 0;
always @(posedge clk) begin
	if (!random_ticks) begin
		mc_tick <= (mc_div == 7'd97) && !reset;   // tick when mc_div == 98 (as hil_card)
		mc_div  <= (reset || mc_div == 7'd98) ? 7'd0 : mc_div + 7'd1;
	end
	else mc_tick <= ($urandom % 6) == 0 || ($urandom % 50) == 0;
end
// note: mc_tick is registered here (one clock after mc_div == 97 -> 98), the
// same clock as hil_card's combinational tick.

//----------------------------------------------------------------------------
// HIL side: P1 input, T0/T1, P2 input (shared, driven from the reference)
//----------------------------------------------------------------------------
reg [7:0] mlc_byte = 8'h00;
always @(posedge clk) begin
	if (r_p1rd || ($urandom % 3000) == 0) mlc_byte <= $urandom;
	if (($urandom % 2500) == 0) t0 <= !t0;
	if (($urandom % 20000) == 0) t1 <= !t1;
	if (($urandom % 50000) == 0) p2_in <= ($urandom % 2) ? 8'hDF : $urandom;
end
always @(*) begin
	if ((r_p2[0] | r_p2[2]) == 1'b0)       p1_in = mlc_byte;               // MLC read
	else if (r_p2[1] == 1'b0)              p1_in = {4'h0, mlc_byte[3:0] ^ r_p1[3:0]};  // "RTC"
	else                                   p1_in = 8'hFF ^ (r_p1 & mlc_byte & 8'h0F);
end

//----------------------------------------------------------------------------
// Comparison
//----------------------------------------------------------------------------
task automatic fail(input string what, input longint got, input longint exp);
	if (errors < 30)
		$display("MISMATCH @%0d: %s dut=%h ref=%h (ref pc=%h st=%0d op=%h)", cyc, what, got, exp,
		         ref_cpu.pc, ref_cpu.st, ref_cpu.op);
	errors++;
endtask

task automatic compare_ram;
	for (int i = 0; i < 256; i++)
		if (dut.ram[i] !== ref_cpu.ram[i]) fail($sformatf("ram[%02h]", i), dut.ram[i], ref_cpu.ram[i]);
endtask

`define CMP(n, x) if (dut.x !== ref_cpu.x) fail(n, dut.x, ref_cpu.x);

always @(negedge clk) if (running) begin
	cyc++;
	if (d_pc   !== r_pc)   fail("dbg_pc", d_pc, r_pc);
	if (d_disp !== r_disp) fail("dbg_dispatch", d_disp, r_disp);
	if (d_p1   !== r_p1)   fail("p1_out", d_p1, r_p1);
	if (d_p2   !== r_p2)   fail("p2_out", d_p2, r_p2);
	if (d_p1rd !== r_p1rd) fail("p1_rd", d_p1rd, r_p1rd);
	if (d_dout !== r_dout) fail("host_dout", d_dout, r_dout);
	`CMP("st", st) `CMP("pc", pc) `CMP("a", a) `CMP("psw", psw) `CMP("f1", f1)
	`CMP("timer", timer) `CMP("prescaler", prescaler) `CMP("timer_run", timer_run)
	`CMP("timer_flag", timer_flag) `CMP("timer_ovf", timer_ovf) `CMP("tirq_en", tirq_en)
	`CMP("xirq_en", xirq_en) `CMP("flags_en", flags_en) `CMP("dma_en", dma_en)
	`CMP("irq_busy", irq_busy) `CMP("irq_polled", irq_polled)
	`CMP("polled_target", polled_target) `CMP("sts", sts) `CMP("dbbi", dbbi)
	`CMP("dbbo", dbbo) `CMP("debt", debt)
	if (ref_cpu.st == 3'd4) `CMP("op", op)
	if (cyc[11:0] == 0) compare_ram();

	if (r_disp) begin n_disp++; seen_pc[r_pc] = 1; end
	if (ref_cpu.st == 3'd4) seen_op[ref_cpu.op] = 1;
	if (!reset && ref_cpu.st == 3'd0 && ref_cpu.take_x) n_irq_x++;
	if (!reset && ref_cpu.st == 3'd0 && ref_cpu.take_t) n_irq_t++;
	if (mc_tick) n_ticks++;
end

//----------------------------------------------------------------------------
// Host
//----------------------------------------------------------------------------
task automatic host_access(input bit we, input bit a0, input [7:0] d, output [7:0] q);
	int len;
	len = 1 + (($urandom % 8) == 0 ? ($urandom % 3) : 0);
	@(negedge clk);
	host_cs = 1; host_we = we; host_a0 = a0; host_din = d;
	#1 q = r_dout;
	repeat (len) @(negedge clk);
	host_cs = 0; host_we = 0; host_din = $urandom;
	if (we) n_hwr++; else n_hrd++;
endtask

task automatic idle(input int n);
	repeat (n) @(negedge clk);
endtask

// poll the status until (status & mask) == want, at most `tries` reads
task automatic poll(input [7:0] mask, input [7:0] want, input int tries, output bit ok);
	reg [7:0] s;
	ok = 0;
	for (int i = 0; i < tries && !ok; i++) begin
		host_access(0, 1, 8'h00, s);
		if ((s & mask) == want) ok = 1;
		else idle(20 + $urandom % 400);
	end
endtask

task automatic command(input [7:0] cmd, input int ndata_in, input int nread);
	bit ok; reg [7:0] q;
	poll(8'h02, 8'h00, 200, ok);                  // IBF clear
	host_access(1, 1, cmd, q);
	for (int i = 0; i < ndata_in; i++) begin
		poll(8'h02, 8'h00, 200, ok);
		host_access(1, 0, $urandom, q);
	end
	for (int i = 0; i < nread; i++) begin
		poll(8'h01, 8'h01, 300, ok);              // OBF set
		if (ok) host_access(0, 0, 8'h00, q);
	end
endtask

initial begin : host
	reg [7:0] q;
	int k;
	wait (running);
	idle(30000);
	forever begin
		k = $urandom % 16;
		case (k)
		0, 1:  command(8'h31, 0, 1 + $urandom % 2);           // boot ROM: read config
		2:     command(8'h5C, 0, 1);
		3:     command(8'h5D, 0, 1);
		4:     command(8'hC2, 1 + $urandom % 3, $urandom % 3); // RTC
		5:     command(8'hC3, $urandom % 3, 1 + $urandom % 3);
		6:     command(8'hA3, 1 + $urandom % 2, 0);            // tone
		7:     command(8'hF0 | ($urandom % 16), 0, 1);
		8:     command($urandom, $urandom % 3, $urandom % 3);
		9, 10: host_access($urandom % 2, $urandom % 2, $urandom, q);  // any time
		11:    begin                                         // burst, ignoring status
			for (int i = 0; i < 1 + $urandom % 6; i++) begin
				host_access($urandom % 2, $urandom % 2, $urandom, q);
				idle($urandom % 5);
			end
		end
		default: ;
		endcase
		idle($urandom % (k > 11 ? 8000 : 1500));
	end
end

//----------------------------------------------------------------------------
// Main
//
// +randrom: instead of the firmware, run random programs (a new one after
// every reset, about every 150k clocks) so every opcode is exercised,
// including the ones the firmware never uses (XCHD, DA A, ADDC Rn, MOVP3,
// RETR without an interrupt, stack wrap-around, illegal opcodes, ...).
//----------------------------------------------------------------------------
bit randrom = 0;

task automatic random_rom;
	for (int i = 0; i < 2048; i++) img[i] = $urandom;
endtask

// load img through rom_wr (call with reset asserted)
task automatic load_rom;
	for (int i = 0; i < 2048; i++) begin
		@(negedge clk);
		rom_wr = 1; rom_addr = i[10:0]; rom_data = img[i];
	end
	@(negedge clk); rom_wr = 0;
endtask

initial begin
	int fd, n, used_ops, used_pcs;
	longint next_reset;
	if (!$value$plusargs("rom=%s", rom_file)) rom_file = "scratch/roms/human_interface/1820-4784.bin";
	void'($value$plusargs("cycles=%d", cycles));
	void'($value$plusargs("seed=%d", seed));
	void'($urandom(seed));
	randrom = $test$plusargs("randrom");
	if (randrom) random_rom();
	else begin
		fd = $fopen(rom_file, "rb");
		if (fd == 0) begin $display("FATAL: cannot open %0s", rom_file); $finish; end
		n = $fread(img, fd);
		$fclose(fd);
		if (n != 2048) begin $display("FATAL: ROM is %0d bytes, expected 2048", n); $finish; end
	end

	// identical, random start-up RAM contents and timer in both cores
	for (int i = 0; i < 256; i++) begin
		q_init = $urandom;
		ref_cpu.ram[i] = q_init; dut.ram[i] = q_init;
	end
	q_init = $urandom; ref_cpu.timer = q_init; dut.timer = q_init;

	load_rom();
	repeat (5) @(negedge clk);
	running = 1;
	reset = 0;

	next_reset = randrom ? 100000 + $urandom % 100000 : cycles / 5 + $urandom % 100000;
	while (cyc < cycles) begin
		@(negedge clk);
		if (cyc == cycles / 2) begin
			random_ticks = 1;
			$display("[%0d] switching to random machine-cycle ticks (%0d dispatches so far)", cyc, n_disp);
		end
		if (cyc >= next_reset) begin                // reset at a random point
			reset = 1;
			repeat (1 + $urandom % 4) @(negedge clk);
			if (randrom) begin random_rom(); load_rom(); end   // new random program
			reset = 0;
			n_resets++;
			next_reset = cyc + (randrom ? 100000 + $urandom % 100000 : cycles / 4 + $urandom % 200000);
		end
	end
	compare_ram();
	used_ops = 0; used_pcs = 0;
	for (int i = 0; i < 256; i++) used_ops += seen_op[i];
	for (int i = 0; i < 2048; i++) used_pcs += seen_pc[i];
	$display("clocks %0d, instructions compared %0d, machine-cycle ticks %0d", cyc, n_disp, n_ticks);
	$display("IBF interrupts %0d, timer interrupts %0d, host writes %0d, host reads %0d, resets %0d",
	         n_irq_x, n_irq_t, n_hwr, n_hrd, n_resets);
	$display("distinct opcodes executed %0d, distinct ROM addresses dispatched %0d", used_ops, used_pcs);
	$write("opcodes executed:");
	for (int i = 0; i < 256; i++) if (seen_op[i]) $write(" %02h", i[7:0]);
	$display("");
	if (errors == 0) $display("PASS: no mismatches");
	else             $display("FAIL: %0d mismatches", errors);
	$finish;
end
reg [7:0] q_init;

endmodule
