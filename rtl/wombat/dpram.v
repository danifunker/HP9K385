// dpram — project-level true-dual-port RAM for the AP68040 submodule.
//
// Replaces rtl/ap68040/rtl/primitives/dpram.v in BOTH build flows (see
// files.qip and verilator/Makefile); the submodule itself is untouched,
// Quartus and Verilator resolve the module by name.  The AP68040 README
// sanctions exactly this substitution.
//
// Why: the submodule's stub is a bare inferred array with a write port on
// each side.  Writes on both ports imply mixed-port OLD-data semantics,
// which Cyclone V M10K cannot provide — Quartus builds the whole array out
// of ALMs instead (ctag_ram: 4,366 ALUTs / 12,126 registers for 12,032
// bits of storage).  The explicit altsyncram below asks for the one thing
// M10K does support, mixed-port DONT_CARE, which both instantiation sites
// were designed for:
//
//  - ap040_cache ctag_ram: "mixed-port read-during-write is DONT_CARE on
//    silicon" (its own comment).  A snoop (port B) landing on the row a
//    lookup or fill (port A) is reading forces a miss / poisons the fill
//    (look_snooped / fill_snooped); every other port B writer is
//    FSM-exclusive with the consumed port A reads, or clears the very row
//    whose read it corrupts (over-invalidation is correctness-safe).
//  - ap040_mmu atc_ram: the lookup pipe drops its freshness bit when its
//    port A read was clocked in a fill_we cycle (l_ld <= ... && !fill_we),
//    so a collided read is never consumed.  Port B's read-modify-write
//    composes q_b DURING the write cycle, which still holds the pre-write
//    row (the output register updates on the edge).
//
// Same-port read-during-write: the stub yields OLD data, M10K NEW data.
// No consumer reads q_a/q_b in the cycle after a same-port write (the
// cache re-reads through a fresh C_IDLE acceptance; the walker re-reads
// for many cycles before the next W_FILL), so the difference is inert.
//
// The Verilator branch keeps the stub's exact behavior, so sim remains
// bit-identical to the pre-wrapper baseline.

module dpram #(parameter AW = 8, parameter DW = 8) (
	input clock,
	input [AW-1:0] address_a,
	input [DW-1:0] data_a,
	input wren_a,
	output [DW-1:0] q_a,
	input [AW-1:0] address_b,
	input [DW-1:0] data_b,
	input wren_b,
	output [DW-1:0] q_b
);

`ifdef VERILATOR

	reg [DW-1:0] mem [0:(1<<AW)-1];
	reg [DW-1:0] q_a_r, q_b_r;
	always @(posedge clock) begin
		if (wren_a) mem[address_a] <= data_a;
		if (wren_b) mem[address_b] <= data_b;
		q_a_r <= mem[address_a];
		q_b_r <= mem[address_b];
	end
	assign q_a = q_a_r;
	assign q_b = q_b_r;

`else

	altsyncram ram
	(
		.clock0    (clock),
		.address_a (address_a),
		.data_a    (data_a),
		.wren_a    (wren_a),
		.q_a       (q_a),

		.address_b (address_b),
		.data_b    (data_b),
		.wren_b    (wren_b),
		.q_b       (q_b),

		.aclr0(1'b0),
		.aclr1(1'b0),
		.addressstall_a(1'b0),
		.addressstall_b(1'b0),
		.byteena_a(1'b1),
		.byteena_b(1'b1),
		.clock1(1'b1),
		.clocken0(1'b1),
		.clocken1(1'b1),
		.clocken2(1'b1),
		.clocken3(1'b1),
		.eccstatus(),
		.rden_a(1'b1),
		.rden_b(1'b1)
	);
	defparam
		ram.numwords_a = 1<<AW,
		ram.widthad_a  = AW,
		ram.width_a    = DW,
		ram.numwords_b = 1<<AW,
		ram.widthad_b  = AW,
		ram.width_b    = DW,
		ram.address_reg_b = "CLOCK0",
		ram.clock_enable_input_a = "BYPASS",
		ram.clock_enable_input_b = "BYPASS",
		ram.clock_enable_output_a = "BYPASS",
		ram.clock_enable_output_b = "BYPASS",
		ram.indata_reg_b = "CLOCK0",
		ram.intended_device_family = "Cyclone V",
		ram.lpm_type = "altsyncram",
		ram.operation_mode = "BIDIR_DUAL_PORT",
		ram.outdata_aclr_a = "NONE",
		ram.outdata_aclr_b = "NONE",
		ram.outdata_reg_a = "UNREGISTERED",
		ram.outdata_reg_b = "UNREGISTERED",
		ram.power_up_uninitialized = "FALSE",
		ram.ram_block_type = "M10K",
		ram.read_during_write_mode_mixed_ports = "DONT_CARE",
		ram.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
		ram.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
		ram.width_byteena_a = 1,
		ram.width_byteena_b = 1,
		ram.wrcontrol_wraddress_reg_b = "CLOCK0";

`endif

endmodule
