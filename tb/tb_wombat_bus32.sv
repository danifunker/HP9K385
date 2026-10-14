// Ported unchanged from MacQuadra800_MiSTer verilator/tb_wombat_bus32.sv.
`timescale 1ns/1ps

module tb_wombat_bus32;

reg clk = 0;
always #5 clk = ~clk;

reg         nreset = 0;
reg         t_req = 0;
reg         t_write = 0;
reg   [1:0] t_size = 0;
reg  [31:0] t_addr = 0;
reg  [31:0] t_wdata = 0;
reg         t_berr = 0;
wire        t_ack;
wire [31:0] t_rdata;
wire        b_req;
wire        b_write;
wire [31:2] b_addr;
wire  [3:0] b_be;
wire [31:0] b_wdata;
reg         b_ack = 0;
reg  [31:0] b_rdata = 0;

wombat_bus32 dut (
	.clk(clk), .nreset(nreset), .ce(1'b1),
	.t_req(t_req), .t_write(t_write), .t_size(t_size), .t_addr(t_addr),
	.t_wdata(t_wdata), .t_berr(t_berr), .t_ack(t_ack), .t_rdata(t_rdata),
	.t_active(),
	.b_req(b_req), .b_write(b_write), .b_addr(b_addr), .b_be(b_be),
	.b_wdata(b_wdata), .b_ack(b_ack), .b_rdata(b_rdata)
);

integer accepts = 0;

// Synchronous platform memory.  Like quadra800's consumers, it may accept a
// new address after its own one-cycle ack drops even when b_req never falls
// between the two beats of a split transaction.  The transaction adapter
// deliberately registers this completion once before exposing t_ack: IOSB
// and the other devices rely on that established retirement cadence.
always @(posedge clk) begin
	b_ack <= 0;
	if (b_req && !b_ack) begin
		b_ack <= 1;
		accepts <= accepts + 1;
		case (b_addr)
			30'h00000100: b_rdata <= 32'h1122_3344;
			30'h00000101: b_rdata <= 32'h5566_7788;
			default:       b_rdata <= {b_addr[17:2], b_addr[17:2]};
		endcase
	end
end

integer checks = 0;
integer fails = 0;
integer last_cycles;
reg [31:0] got;

task check(input bit cond, input string what);
	begin
		checks = checks + 1;
		if (cond) $display("PASS  %s", what);
		else begin
			fails = fails + 1;
			$display("FAIL  %s", what);
		end
	end
endtask

task automatic transact(input [1:0] size_i, input [31:0] addr_i);
	integer n;
	begin
		@(negedge clk);
		t_size = size_i;
		t_addr = addr_i;
		t_write = 0;
		t_req = 1;
		n = 0;
		forever begin
			@(negedge clk);
			n = n + 1;
			if (t_ack) begin
				got = t_rdata;
				t_req = 0;
				break;
			end
		end
		last_cycles = n;
	end
endtask

integer a0;
initial begin
	repeat (3) @(posedge clk);
	nreset = 1;

	a0 = accepts;
	transact(2'd2, 32'h0000_0400);
	check(got == 32'h1122_3344, "aligned longword returns platform data");
	check(accepts == a0 + 1, "aligned longword issues exactly one beat");
	check(last_cycles == 3, "one-beat transfer retains registered completion");

	transact(2'd0, 32'h0000_0401);
	check(got == 32'h0000_0022, "fast path right-aligns a byte read");

	a0 = accepts;
	transact(2'd2, 32'h0000_0403);
	check(got == 32'h4455_6677, "misaligned longword combines two beats");
	check(accepts == a0 + 2, "misaligned longword issues two beats without duplication");

	$display("tb_wombat_bus32: %0d checks, %0d failures", checks, fails);
	if (fails == 0) $display("tb_wombat_bus32: OK");
	else            $display("tb_wombat_bus32: FAILED");
	$finish;
end

initial begin
	#10000;
	$fatal(1, "tb_wombat_bus32 timeout");
end

endmodule
