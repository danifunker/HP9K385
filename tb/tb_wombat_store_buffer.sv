// Ported from MacQuadra800_MiSTer verilator/tb_wombat_store_buffer.sv @ 011f7d9-era tree.
`timescale 1ns/1ps

module tb_wombat_store_buffer;

reg clk = 0;
always #5 clk = ~clk;

reg         nreset = 0;
reg         ce = 1;
reg         buffer_writes = 1;
reg         s_req = 0;
reg         s_write = 0;
reg         s_instr = 0;
reg  [1:0]  s_size = 2'd2;
reg  [31:0] s_addr = 0;
reg  [31:0] s_wdata = 0;
reg  [2:0]  s_fc = 3'd5;
wire        s_ack;
wire [31:0] s_rdata;

wire        m_req;
wire        m_write;
wire        m_instr;
wire [1:0]  m_size;
wire [31:0] m_addr;
wire [31:0] m_wdata;
wire [2:0]  m_fc;
reg         m_ack = 0;
reg  [31:0] m_rdata = 0;
reg         m_err = 0;
wire        pending;

integer errors = 0;
integer guard;

wombat_store_buffer dut (
	.clk(clk), .nreset(nreset), .ce(ce),
	.buffer_writes(buffer_writes),
	// HP9K385: the address window became an input; drive it with the
	// Quadra decode this bench was written against (RAM below 1 GB plus
	// the DAFB VRAM window) so the bench checks the refactor is neutral.
	.post_window((s_addr[31:30] == 2'b00) || (s_addr[31:21] == 11'b1111_1001_000)),
	.s_req(s_req), .s_write(s_write), .s_instr(s_instr),
	.s_size(s_size), .s_addr(s_addr), .s_wdata(s_wdata), .s_fc(s_fc),
	.s_ack(s_ack), .s_rdata(s_rdata),
	.m_req(m_req), .m_write(m_write), .m_instr(m_instr),
	.m_size(m_size), .m_addr(m_addr), .m_wdata(m_wdata), .m_fc(m_fc),
	.m_ack(m_ack), .m_rdata(m_rdata), .m_err(m_err),
	.pending(pending)
);

task fail;
	input [8*120-1:0] message;
	begin
		$display("FAIL: %0s", message);
		errors = errors + 1;
	end
endtask

task buffered_store;
	input [31:0] addr;
	input [31:0] data;
	begin
		@(negedge clk);
		s_req = 1; s_write = 1; s_instr = 0;
		s_size = 2'd2; s_addr = addr; s_wdata = data; s_fc = 3'd5;
		guard = 0;
		while (!s_ack && guard < 30) begin
			@(posedge clk);
			guard = guard + 1;
		end
		if (guard >= 30) fail("buffered store did not receive its capture ack");
		if (m_ack) fail("buffered store capture coincided with downstream ack");
		@(negedge clk);
		s_req = 0;
	end
endtask

task expect_head;
	input [31:0] addr;
	input [31:0] data;
	begin
		guard = 0;
		while (!(m_req && m_write) && guard < 30) begin
			@(posedge clk);
			guard = guard + 1;
		end
		if (guard >= 30) fail("buffered write did not reach the drain port");
		else begin
			if (m_addr !== addr) begin
				$display("FAIL: drain address %h expected %h", m_addr, addr);
				errors = errors + 1;
			end
			if (m_wdata !== data) begin
				$display("FAIL: drain data %h expected %h", m_wdata, data);
				errors = errors + 1;
			end
		end
	end
endtask

task ack_head;
	begin
		@(negedge clk);
		m_ack = 1;
		@(posedge clk);
		@(negedge clk);
		m_ack = 0;
	end
endtask

initial begin
	repeat (4) @(negedge clk);
	nreset = 1;
	repeat (3) @(posedge clk);

	//------------------------------------------------------------------
	// T1: a direct read keeps the established downstream completion.
	//------------------------------------------------------------------
	@(negedge clk);
	s_req = 1; s_write = 0; s_addr = 32'h1000_0040; s_size = 2'd2;
	guard = 0;
	while (!dut.direct_active && guard < 20) begin
		@(posedge clk);
		guard = guard + 1;
	end
	if (guard >= 20 || !m_req || m_write) fail("direct read was not forwarded");
	if (s_ack) fail("direct read acknowledged without downstream ack");
	@(negedge clk);
	m_rdata = 32'h1234_5678;
	m_ack = 1;
	#1;
	if (!s_ack || s_rdata !== 32'h1234_5678)
		fail("direct read did not return downstream data and ack");
	@(posedge clk);
	@(negedge clk);
	m_ack = 0; s_req = 0;
	repeat (2) @(posedge clk);

	//------------------------------------------------------------------
	// T2: a RAM store retires before downstream ack. A following read
	// remains blocked until the older write drains.
	//------------------------------------------------------------------
	buffered_store(32'h0000_1000, 32'hA0A0_0001);
	if (!pending) fail("pending dropped before the captured store drained");
	expect_head(32'h0000_1000, 32'hA0A0_0001);

	@(negedge clk);
	s_req = 1; s_write = 0; s_addr = 32'h0000_2000;
	repeat (3) @(posedge clk);
	if (!m_req || !m_write || m_addr !== 32'h0000_1000)
		fail("younger read passed an older buffered store");
	if (s_ack) fail("younger read acknowledged before the store drained");
	ack_head();

	guard = 0;
	while (!(m_req && !m_write && dut.direct_active) && guard < 30) begin
		@(posedge clk);
		guard = guard + 1;
	end
	if (guard >= 30 || m_addr !== 32'h0000_2000)
		fail("ordered read did not start after the store drained");
	@(negedge clk);
	m_rdata = 32'hCAFE_BABE;
	m_ack = 1;
	#1;
	if (!s_ack || s_rdata !== 32'hCAFE_BABE)
		fail("ordered read returned the wrong completion");
	@(posedge clk);
	@(negedge clk);
	m_ack = 0; s_req = 0;
	repeat (2) @(posedge clk);

	//------------------------------------------------------------------
	// T3: two writes queue. A third is backpressured while full, then
	// enters the freed slot and all three drain in program order.
	//------------------------------------------------------------------
	buffered_store(32'h0000_3000, 32'hB0B0_0001);
	buffered_store(32'h0000_3004, 32'hB0B0_0002);
	expect_head(32'h0000_3000, 32'hB0B0_0001);

	@(negedge clk);
	s_req = 1; s_write = 1; s_addr = 32'h0000_3008;
	s_wdata = 32'hB0B0_0003;
	repeat (3) @(posedge clk);
	if (s_ack) fail("full queue acknowledged a third store");
	ack_head();

	guard = 0;
	while (!s_ack && guard < 30) begin
		@(posedge clk);
		guard = guard + 1;
	end
	if (guard >= 30) fail("third store was not accepted after a slot freed");
	@(negedge clk);
	s_req = 0;

	expect_head(32'h0000_3004, 32'hB0B0_0002);
	ack_head();
	expect_head(32'h0000_3008, 32'hB0B0_0003);
	ack_head();
	repeat (3) @(posedge clk);
	if (pending || m_req) fail("queue did not become idle after ordered drain");

	//------------------------------------------------------------------
	// T4: a read of another line passes the one queued store that is not
	// yet draining (the second of two: the first drains, the read wins the
	// bus before the second), a read of the SAME line waits, and a full
	// queue drains first.  (2026-09-19)
	//------------------------------------------------------------------
	buffered_store(32'h0000_4000, 32'hC0C0_0001);
	buffered_store(32'h0000_4010, 32'hC0C0_0002);
	expect_head(32'h0000_4000, 32'hC0C0_0001);
	@(negedge clk);
	s_req = 1; s_write = 0; s_addr = 32'h0000_5000;   // another line
	repeat (3) @(posedge clk);
	if (s_ack) fail("T4: read acknowledged under a full queue");
	if (!(m_req && m_write && m_addr == 32'h0000_4000)) fail("T4: full queue did not keep draining first");
	ack_head();                                        // the first store lands; count 1
	guard = 0;
	while (!(m_req && !m_write && dut.direct_active) && guard < 30) begin
		@(posedge clk);
		guard = guard + 1;
	end
	if (guard >= 30 || m_addr !== 32'h0000_5000) fail("T4: read of another line did not pass the queued store");
	@(negedge clk);
	m_rdata = 32'h5555_0001; m_ack = 1;
	#1;
	if (!s_ack || s_rdata !== 32'h5555_0001) fail("T4: passing read returned the wrong completion");
	@(posedge clk);
	@(negedge clk);
	m_ack = 0; s_req = 0;
	expect_head(32'h0000_4010, 32'hC0C0_0002);        // the passed store drains after it
	// a read of the queued store's own line must wait for it
	@(negedge clk);
	s_req = 1; s_write = 0; s_addr = 32'h0000_4014;
	repeat (3) @(posedge clk);
	if (s_ack) fail("T4: same-line read acknowledged before the store drained");
	if (!(m_req && m_write)) fail("T4: same-line read displaced the store's drain");
	ack_head();
	guard = 0;
	while (!(m_req && !m_write && dut.direct_active) && guard < 30) begin
		@(posedge clk);
		guard = guard + 1;
	end
	if (guard >= 30 || m_addr !== 32'h0000_4014) fail("T4: same-line read did not start after the store drained");
	@(negedge clk);
	m_rdata = 32'h5555_0002; m_ack = 1;
	@(posedge clk);
	@(negedge clk);
	m_ack = 0; s_req = 0;
	repeat (3) @(posedge clk);
	if (pending || m_req) fail("T4: queue did not become idle");
	// a same-line read presented right after the capture of a single store
	// must not pass it either
	buffered_store(32'h0000_6000, 32'hD0D0_0001);
	@(negedge clk);
	s_req = 1; s_write = 0; s_addr = 32'h0000_600C;
	repeat (2) @(posedge clk);
	if (dut.direct_active) fail("T4: same-line read passed a freshly captured store");
	expect_head(32'h0000_6000, 32'hD0D0_0001);
	ack_head();
	guard = 0;
	while (!(m_req && !m_write && dut.direct_active) && guard < 30) begin
		@(posedge clk);
		guard = guard + 1;
	end
	if (guard >= 30 || m_addr !== 32'h0000_600C) fail("T4: same-line read did not follow the store");
	@(negedge clk);
	m_ack = 1;
	@(posedge clk);
	@(negedge clk);
	m_ack = 0; s_req = 0;
	repeat (3) @(posedge clk);
	if (pending || m_req) fail("T4: queue did not become idle after the same-line read");

	//------------------------------------------------------------------
	// T5: line-crossing transfers never pass.  The cache posts a store
	// that straddles two 16-byte lines unsplit (a long at $xE: 68k stacks
	// are only word-aligned) and invalidates both lines, so the next read
	// of the SECOND line is a fill that must see the store's tail; and a
	// bypass read that straddles two lines must see a store queued to its
	// second line.  pass_ok compared only the first line of each.
	//------------------------------------------------------------------
	buffered_store(32'h0000_7000, 32'hE0E0_0001);
	buffered_store(32'h0000_701E, 32'hE0E0_0002);      // bytes 701E..7021
	expect_head(32'h0000_7000, 32'hE0E0_0001);
	@(negedge clk);
	s_req = 1; s_write = 0; s_size = 2'd2; s_addr = 32'h0000_7020;   // the store's second line
	ack_head();                                        // the first store lands; count 1
	repeat (2) @(posedge clk);
	if (dut.direct_active) fail("T5: a read of a crossing store's second line passed it");
	expect_head(32'h0000_701E, 32'hE0E0_0002);
	ack_head();
	guard = 0;
	while (!(m_req && !m_write && dut.direct_active) && guard < 30) begin
		@(posedge clk);
		guard = guard + 1;
	end
	if (guard >= 30 || m_addr !== 32'h0000_7020) fail("T5: the second-line read did not follow the crossing store");
	@(negedge clk);
	m_ack = 1;
	@(posedge clk);
	@(negedge clk);
	m_ack = 0; s_req = 0;
	repeat (3) @(posedge clk);
	if (pending || m_req) fail("T5: queue did not become idle after the crossing store");
	// the mirror: a crossing READ against a store queued to its second line
	buffered_store(32'h0000_8000, 32'hF0F0_0001);
	buffered_store(32'h0000_8020, 32'hF0F0_0002);
	expect_head(32'h0000_8000, 32'hF0F0_0001);
	@(negedge clk);
	s_req = 1; s_write = 0; s_size = 2'd2; s_addr = 32'h0000_801E;   // bytes 801E..8021
	ack_head();
	repeat (2) @(posedge clk);
	if (dut.direct_active) fail("T5: a crossing read passed a store queued to its second line");
	expect_head(32'h0000_8020, 32'hF0F0_0002);
	ack_head();
	guard = 0;
	while (!(m_req && !m_write && dut.direct_active) && guard < 30) begin
		@(posedge clk);
		guard = guard + 1;
	end
	if (guard >= 30 || m_addr !== 32'h0000_801E) fail("T5: the crossing read did not follow the store");
	@(negedge clk);
	m_ack = 1;
	@(posedge clk);
	@(negedge clk);
	m_ack = 0; s_req = 0;
	// a word at $xF crosses too; a word at $xE and a byte at $xF do not
	buffered_store(32'h0000_9000, 32'hA0A0_0001);
	buffered_store(32'h0000_9020, 32'hA0A0_0002);
	expect_head(32'h0000_9000, 32'hA0A0_0001);
	@(negedge clk);
	s_req = 1; s_write = 0; s_size = 2'd1; s_addr = 32'h0000_901F;   // bytes 901F..9020
	ack_head();
	repeat (2) @(posedge clk);
	if (dut.direct_active) fail("T5: a crossing word read passed a store queued to its second line");
	expect_head(32'h0000_9020, 32'hA0A0_0002);
	ack_head();
	guard = 0;
	while (!(m_req && !m_write && dut.direct_active) && guard < 30) begin
		@(posedge clk);
		guard = guard + 1;
	end
	if (guard >= 30) fail("T5: the crossing word read did not follow the store");
	@(negedge clk);
	m_ack = 1;
	@(posedge clk);
	@(negedge clk);
	m_ack = 0; s_req = 0; s_size = 2'd2;
	repeat (3) @(posedge clk);
	if (pending || m_req) fail("T5: queue did not become idle");
	// a word at $xE of another line still passes (it does not cross)
	buffered_store(32'h0000_A000, 32'hB0B0_0001);
	buffered_store(32'h0000_A020, 32'hB0B0_0002);
	expect_head(32'h0000_A000, 32'hB0B0_0001);
	@(negedge clk);
	s_req = 1; s_write = 0; s_size = 2'd1; s_addr = 32'h0000_A01E;   // bytes A01E..A01F
	ack_head();
	guard = 0;
	while (!(m_req && !m_write && dut.direct_active) && guard < 30) begin
		@(posedge clk);
		guard = guard + 1;
	end
	if (guard >= 30 || m_addr !== 32'h0000_A01E) fail("T5: a non-crossing word read at $xE no longer passes");
	@(negedge clk);
	m_ack = 1;
	@(posedge clk);
	@(negedge clk);
	m_ack = 0; s_req = 0; s_size = 2'd2;
	expect_head(32'h0000_A020, 32'hB0B0_0002);
	ack_head();
	repeat (3) @(posedge clk);
	if (pending || m_req) fail("T5: queue did not become idle after the non-crossing pass");

	//------------------------------------------------------------------
	// T4: disabling the host qualifier leaves even a low-address write
	// on the ordinary path, so ROM/overlay and faulting targets stay safe.
	//------------------------------------------------------------------
	buffer_writes = 0;
	@(negedge clk);
	s_req = 1; s_write = 1; s_addr = 32'h0000_4000;
	s_wdata = 32'hD0D0_0001;
	guard = 0;
	while (!dut.direct_active && guard < 20) begin
		@(posedge clk);
		guard = guard + 1;
	end
	if (guard >= 20 || !m_req || !m_write)
		fail("non-qualified write was not forwarded directly");
	if (s_ack || pending) fail("non-qualified write was buffered");
	@(negedge clk);
	m_ack = 1;
	#1;
	if (!s_ack) fail("non-qualified write did not pass downstream ack");
	@(posedge clk);
	@(negedge clk);
	m_ack = 0; s_req = 0;
	repeat (3) @(posedge clk);

	//------------------------------------------------------------------
	// T5: ce freezes queue state and acknowledgement generation.
	//------------------------------------------------------------------
	buffer_writes = 1;
	ce = 0;
	@(negedge clk);
	s_req = 1; s_write = 1; s_addr = 32'h0000_5000;
	s_wdata = 32'hE0E0_0001;
	repeat (5) @(posedge clk);
	if (s_ack || pending || m_req) fail("queue changed while ce was frozen");
	ce = 1;
	guard = 0;
	while (!s_ack && guard < 20) begin
		@(posedge clk);
		guard = guard + 1;
	end
	if (guard >= 20) fail("queue did not resume after ce was restored");
	@(negedge clk);
	s_req = 0;
	expect_head(32'h0000_5000, 32'hE0E0_0001);
	ack_head();
	repeat (3) @(posedge clk);

	//------------------------------------------------------------------
	// T6: a store into the DAFB VRAM window is posted like a RAM store;
	// a following DAFB register write (a device transaction) and a VRAM
	// read-back both wait until it has drained, and a ROM-window write
	// still goes the direct way.
	//------------------------------------------------------------------
	buffered_store(32'hF903_D028, 32'hF0F0_0001);
	if (!pending) fail("VRAM store was not queued");
	expect_head(32'hF903_D028, 32'hF0F0_0001);
	@(negedge clk);
	s_req = 1; s_write = 1; s_addr = 32'hF980_0010; s_wdata = 32'h0000_0030;
	repeat (2) @(posedge clk);
	if (s_ack) fail("DAFB register write passed a queued VRAM store");
	if (!m_req || !m_write || m_addr !== 32'hF903_D028)
		fail("VRAM store left the drain port before its ack");
	ack_head();
	guard = 0;
	while (!(m_req && m_write && m_addr == 32'hF980_0010) && guard < 30) begin
		@(posedge clk);
		guard = guard + 1;
	end
	if (guard >= 30) fail("DAFB register write did not follow the drained VRAM store");
	if (s_ack || pending) fail("DAFB register write was buffered");
	@(negedge clk);
	m_ack = 1;
	#1;
	if (!s_ack) fail("DAFB register write did not pass downstream ack");
	@(posedge clk);
	@(negedge clk);
	m_ack = 0; s_req = 0;
	repeat (3) @(posedge clk);

	buffered_store(32'hF900_1000, 32'hF0F0_0002);
	@(negedge clk);
	s_req = 1; s_write = 0; s_addr = 32'hF900_1000;
	repeat (2) @(posedge clk);
	if (s_ack) fail("VRAM read-back passed a queued VRAM store");
	expect_head(32'hF900_1000, 32'hF0F0_0002);
	ack_head();
	guard = 0;
	while (!(m_req && !m_write) && guard < 30) begin
		@(posedge clk);
		guard = guard + 1;
	end
	if (guard >= 30) fail("VRAM read-back did not follow the drained store");
	@(negedge clk);
	m_ack = 1; m_rdata = 32'hF0F0_0002;
	#1;
	if (!s_ack || s_rdata !== 32'hF0F0_0002) fail("VRAM read-back completion");
	@(posedge clk);
	@(negedge clk);
	m_ack = 0; s_req = 0;
	repeat (3) @(posedge clk);

	@(negedge clk);
	s_req = 1; s_write = 1; s_addr = 32'h4080_0000; s_wdata = 32'hD0D0_0002;
	guard = 0;
	while (!dut.direct_active && guard < 20) begin
		@(posedge clk);
		guard = guard + 1;
	end
	if (guard >= 20 || !m_req || !m_write)
		fail("ROM-window write was not forwarded directly");
	if (s_ack || pending) fail("ROM-window write was buffered");
	@(negedge clk);
	m_ack = 1;
	#1;
	if (!s_ack) fail("ROM-window write did not pass downstream ack");
	@(posedge clk);
	@(negedge clk);
	m_ack = 0; s_req = 0;
	repeat (3) @(posedge clk);

	if (errors == 0) $display("ALL TESTS PASSED");
	else $display("TEST FAILED with %0d errors", errors);
	$finish;
end

initial begin
	#200000;
	$display("FAIL: global timeout");
	$finish;
end

endmodule
