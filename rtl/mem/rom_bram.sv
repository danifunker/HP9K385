//============================================================================
//  rom_bram — a ROM in block RAM, loaded 16 bits at a time from hps_io and
//  read 32 bits at a time by the machine.
//
//  Two 16-bit halves (hi = bits 31:16, the longword's first two bytes), so
//  a download word writes one half with no read-modify-write.  The read is
//  synchronous: q is the longword at raddr one clock later.
//============================================================================

module rom_bram
#(
	parameter AW = 15                   // longword address bits (15 = 128 KB)
)
(
	input               clk,

	input               we,
	input      [AW-1:0] waddr,
	input               whalf,          // 0: bits 31:16, 1: bits 15:0
	input        [15:0] wdata,

	input      [AW-1:0] raddr,
	output reg   [31:0] q
);

reg [15:0] hi [0:(1 << AW) - 1];
reg [15:0] lo [0:(1 << AW) - 1];

always @(posedge clk) begin
	if (we && !whalf) hi[waddr] <= wdata;
	if (we &&  whalf) lo[waddr] <= wdata;
	q <= {hi[raddr], lo[raddr]};
end

endmodule
