// Unit bench for rtl/lan_wire.sv (Verilator): the 98643A's mailbox client
// against a model of the DDR3 mailbox (64 KB of 64-bit words behind the
// nb_* port, random ack latency, the 715 ddr3_port's "req && !ack" take
// rule) and a fake Main that does what support/hp9k/hp9k_enet.cpp's
// hp9k_enet_poll() does, at random intervals: it ignores the mailbox until
// it knows the magic, follows GEN and the MAC word, drains TX slots
// (checked against what the LANCE model sent: length, bytes, so no FCS) and
// "sends" them to a network that echoes them back; it posts network frames
// into RX slots padded to 60 with the FCS appended and the hash in bits
// 21:16, dropping them when the ring is full.  A behavioural LANCE writes
// TX frames through tx_* and takes RX frames through rx_*.
//
// Checked: start-up order (MAGIC = 0 first, GEN, the pointers zeroed, the
// MAC word, MAGIC last) at power-up and after a reset that lands on a
// mailbox word in flight (GEN must change, the word must not be withdrawn);
// the MAC word after mac_stb (valid bit, byte order); TX echo of short,
// odd and full-size frames; an RX burst larger than the ring, with a frame
// over 1522 bytes that must be skipped; 10 Mb/s pacing of every frame
// offered (not before its wire time from when its slot header was read);
// RX_RPTR held while the LANCE has the frame and advanced on rx_done; the
// TX-full wait (frame posted once Main runs again) and the timeout drop;
// TX dropped and RX skipped with ena = 0; the nb_* handshake throughout.
// Timing parameters are accelerated (POLL, TXPOLL, TXWAIT); pacing is real.
`timescale 1ns/1ps
module tb_lan_wire;
localparam CLK_HZ = 33_000_000, BIT_HZ = 10_000_000;
localparam POLL = 1500, TXPOLL = 256, TXWAIT = 20_000;
localparam [63:0] MAGIC = 64'h4833_4554_4830_3031;

reg clk = 0, reset = 1;
always #15 clk = !clk;
integer cyc = 0;
always @(posedge clk) cyc <= cyc + 1;
integer errors = 0;

// ---- DUT -------------------------------------------------------------------
reg         ena = 1;
reg  [47:0] mac = 48'h0800_0912_3456;
reg         mac_stb = 0;
wire        tx_ready;
reg         tx_we = 0, tx_send = 0;
reg  [10:0] tx_addr = 0, tx_len = 0;
reg   [7:0] tx_wdata = 0;
wire        rx_avail;
wire [10:0] rx_len;
reg  [10:0] rx_addr = 0;
wire  [7:0] rx_q;
reg         rx_done = 0;
wire        nb_req, nb_we;
wire [12:0] nb_addr;
wire [63:0] nb_wdata;
reg         nb_ack = 0;
reg  [63:0] nb_rdata = 0;

lan_wire #(.CLK_HZ(CLK_HZ), .BIT_HZ(BIT_HZ), .POLL(POLL), .TXPOLL(TXPOLL), .TXWAIT(TXWAIT)) dut(
	.clk(clk), .reset(reset), .ena(ena), .mac(mac), .mac_stb(mac_stb),
	.tx_ready(tx_ready), .tx_we(tx_we), .tx_addr(tx_addr), .tx_wdata(tx_wdata), .tx_send(tx_send), .tx_len(tx_len),
	.rx_avail(rx_avail), .rx_len(rx_len), .rx_addr(rx_addr), .rx_q(rx_q), .rx_done(rx_done),
	.nb_req(nb_req), .nb_we(nb_we), .nb_addr(nb_addr), .nb_wdata(nb_wdata), .nb_ack(nb_ack), .nb_rdata(nb_rdata));

// ---- the mailbox: 8K words behind nb_*, random latency ----------------------
reg  [63:0] mb [0:8191];
integer     log_n = 0;                       // accesses taken since the log was cleared
reg  [12:0] log_a  [0:4095];
reg         log_we [0:4095];
reg  [63:0] log_d  [0:4095];
integer     hdr_t  [0:15];                   // cycle each RX slot's header was read
integer     lat = 0;
reg         busy = 0, h_we;
reg  [12:0] h_a;
reg  [63:0] h_d;
always @(posedge clk) begin
	nb_ack <= 0;
	if (!busy && nb_req && !nb_ack) begin
		busy <= 1; h_a <= nb_addr; h_we <= nb_we; h_d <= nb_wdata;
		lat <= 1 + ($urandom % 24);
		if (log_n < 4096) begin
			log_a[log_n] = nb_addr; log_we[log_n] = nb_we; log_d[log_n] = nb_wdata;
			log_n = log_n + 1;
		end
	end else if (busy) begin
		if (lat > 1) lat <= lat - 1;
		else begin
			busy <= 0; nb_ack <= 1;
			if (h_we) mb[h_a] = h_d;
			else begin
				nb_rdata <= mb[h_a];
				if (h_a >= 13'h0A00 && h_a < 13'h1A00 && h_a[7:0] == 8'd0) hdr_t[(h_a - 13'h0A00) >> 8] = cyc;
			end
		end
	end
end

// nb_* handshake: a request is held, unchanged, until its ack
reg        p_req = 0, p_ack = 0, p_we;
reg [12:0] p_a;
reg [63:0] p_d;
always @(posedge clk) begin
	if (p_req && !p_ack && (!nb_req || nb_addr != p_a || nb_we != p_we || (nb_we && nb_wdata != p_d))) begin
		if (errors < 20) $display("FAIL cycle %0d: nb request withdrawn or changed before its ack", cyc);
		errors++;
	end
	p_req <= nb_req; p_ack <= nb_ack; p_a <= nb_addr; p_we <= nb_we; p_d <= nb_wdata;
end

// ---- frames ----------------------------------------------------------------
function [7:0] fbyte(input integer seed, input integer i);
	fbyte = 8'(seed * 37 + i * 11 + (i >> 4) * 3 + (seed >> 3) * i);
endfunction
function [31:0] crc_upd(input [31:0] c, input [7:0] b);
	reg [31:0] r;
	r = c ^ {24'd0, b};
	for (int k = 0; k < 8; k++) r = (r >> 1) ^ (32'hEDB88320 & {32{r[0]}});
	crc_upd = r;
endfunction

// expected TX frames (the LANCE sent them; Main must find them in order)
reg   [7:0] etx [0:31][0:2047];
integer     etx_len [0:31];
integer     etx_h = 0, etx_t = 0;
// network -> Main
reg   [7:0] ibx [0:63][0:2047];
integer     ibx_len [0:63];
integer     ibx_h = 0, ibx_t = 0;
// expected RX frames (Main posted them; the LANCE must be offered them in order)
reg   [7:0] erx [0:31][0:2047];
integer     erx_len [0:31];
reg  [31:0] erx_p [0:31];
integer     erx_h = 0, erx_t = 0;

// ---- fake Main (hp9k_enet_poll) ---------------------------------------------
reg         main_run = 1, echo = 1, rx_expect = 1;
reg  [63:0] main_gen = ~64'd0;
integer     gens_seen = 0;
reg  [47:0] main_mac = 0;
integer     main_tx = 0, main_rx_posted = 0, main_rx_dropped = 0, main_rx_skips = 0;
reg   [7:0] buf8 [0:2047];

function [7:0] mb_byte(input integer off);
	mb_byte = mb[off >> 3][8 * (off & 7) +: 8];
endfunction

task automatic main_poll;
	reg [63:0] txw, txr, rxw, rxr, g;
	integer slot, len, i;
	reg [31:0] c, fcs, hash;
	if (mb[0] == MAGIC) begin                // rx_ring_slots(): 16
		g = mb[1];
		if (g != main_gen) begin main_gen = g; gens_seen++; end
		if (mb[6][63]) main_mac = mb[6][47:0];

		// TX
		txw = mb[2]; txr = mb[3];
		if (txw - txr > 8) begin
			$display("FAIL Main: TX pointers out of step (%0d, %0d)", txw, txr); errors++;
			txr = txw;
		end
		while (txr != txw) begin
			slot = 'h1000 + 'h800 * int'(txr % 8);
			len = int'(mb[slot >> 3][10:0]);
			if (mb[slot >> 3][63:11] != 0) begin $display("FAIL Main: TX slot header %h", mb[slot >> 3]); errors++; end
			if (etx_h == etx_t) begin
				$display("FAIL Main: TX frame (%0d bytes) the LANCE did not send (or should have been dropped)", len); errors++;
			end else begin
				if (len != etx_len[etx_h % 32]) begin
					$display("FAIL Main: TX length %0d, sent %0d", len, etx_len[etx_h % 32]); errors++;
				end else for (i = 0; i < len; i++) if (mb_byte(slot + 8 + i) != etx[etx_h % 32][i]) begin
					if (errors < 20) $display("FAIL Main: TX byte %0d of %0d: %h want %h", i, len, mb_byte(slot + 8 + i), etx[etx_h % 32][i]);
					errors++;
				end
				etx_h++;
			end
			if (echo && len >= 14 && len <= 2040) begin
				for (i = 0; i < len; i++) ibx[ibx_t % 64][i] = mb_byte(slot + 8 + i);
				ibx_len[ibx_t % 64] = len; ibx_t++;
			end
			txr++; main_tx++;
		end
		mb[3] = txr;

		// RX
		while (ibx_h != ibx_t) begin
			len = ibx_len[ibx_h % 64];
			for (i = 0; i < len; i++) buf8[i] = ibx[ibx_h % 64][i];
			ibx_h++;
			rxw = mb[4]; rxr = mb[5];
			if (len < 14) continue;
			if (rxw - rxr >= 16) begin main_rx_dropped++; continue; end
			if (len < 60) begin for (i = len; i < 60; i++) buf8[i] = 0; len = 60; end
			if (len > 2040 - 4) continue;
			c = 32'hFFFFFFFF;
			for (i = 0; i < len; i++) c = crc_upd(c, buf8[i]);
			fcs = ~c;
			for (i = 0; i < 4; i++) buf8[len + i] = fcs[8 * i +: 8];
			len += 4;
			c = 32'hFFFFFFFF;
			for (i = 0; i < 6; i++) c = crc_upd(c, buf8[i]);
			hash = c >> 26;
			slot = 'h5000 + 'h800 * int'(rxw % 16);
			for (i = 0; i < len; i++) mb[(slot + 8 + i) >> 3][8 * ((slot + 8 + i) & 7) +: 8] = buf8[i];
			mb[slot >> 3] = 64'(len) | (64'(hash) << 16);
			mb[4] = rxw + 1;
			main_rx_posted++;
			if (len > 1522) main_rx_skips++;
			else if (rx_expect) begin
				for (i = 0; i < len; i++) erx[erx_t % 32][i] = buf8[i];
				erx_len[erx_t % 32] = len; erx_p[erx_t % 32] = rxw[31:0]; erx_t++;
			end
		end
	end
endtask

initial forever begin
	repeat (200 + $urandom % 2300) @(negedge clk);
	if (main_run && !reset) main_poll();
end

// a frame from "the network"
task automatic inject(input integer len, input integer seed);
	for (int i = 0; i < len; i++) ibx[ibx_t % 64][i] = fbyte(seed, i);
	ibx_len[ibx_t % 64] = len; ibx_t++;
endtask

// ---- behavioural LANCE: TX ----------------------------------------------------
task automatic send_frame(input integer len, input integer seed, input bit expect_main);
	@(negedge clk);
	while (!tx_ready) @(negedge clk);
	for (int i = 0; i < len; i++) begin
		tx_we = 1; tx_addr = 11'(i); tx_wdata = fbyte(seed, i);
		@(negedge clk);
	end
	tx_we = 0;
	if (expect_main) begin
		for (int i = 0; i < len; i++) etx[etx_t % 32][i] = fbyte(seed, i);
		etx_len[etx_t % 32] = len; etx_t++;
	end
	tx_send = 1; tx_len = 11'(len);
	@(negedge clk);
	tx_send = 0;
	if (tx_ready) begin $display("FAIL tx_ready still 1 the clock after tx_send"); errors++; end
endtask

// ---- behavioural LANCE: RX ----------------------------------------------------
integer rx_taken = 0, rx_unexpected = 0;
initial forever begin
	@(posedge clk);
	if (rx_avail && !reset) begin
		integer len, h, el, wire_clk, d;
		reg [31:0] p;
		len = rx_len;
		if (erx_h == erx_t) begin
			$display("FAIL frame offered (%0d bytes) that Main did not post or that should be skipped", len); errors++;
			rx_unexpected++;
			@(negedge clk) rx_done = 1;
			@(negedge clk) rx_done = 0;
		end else begin
			h = erx_h % 32;
			p = erx_p[h];
			if (len != erx_len[h]) begin $display("FAIL rx_len %0d, Main posted %0d", len, erx_len[h]); errors++; end
			// pacing: not offered before its 10 Mb/s wire time from the header read
			el = cyc - hdr_t[p % 16];
			wire_clk = (erx_len[h] + 20) * 8 * (CLK_HZ / 100_000) / (BIT_HZ / 100_000);
			if (el < wire_clk - 8) begin
				$display("FAIL frame %0d (%0d bytes) offered %0d clocks after its header, wire time %0d", p, len, el, wire_clk); errors++;
			end
			if (el > wire_clk + 8000) begin
				$display("FAIL frame %0d (%0d bytes) offered late: %0d clocks, wire time %0d", p, len, el, wire_clk); errors++;
			end
			// RX_RPTR still on this frame while the LANCE has it
			if (mb[5] != 64'(p)) begin $display("FAIL RX_RPTR %0d while frame %0d is held", mb[5], p); errors++; end
			d = $urandom % 300;
			repeat (d) @(posedge clk);
			if (!rx_avail) begin $display("FAIL rx_avail dropped before rx_done"); errors++; end
			for (int i = 0; i < erx_len[h]; i++) begin
				@(negedge clk) rx_addr = 11'(i);
				@(posedge clk); #1;
				if (rx_q != erx[h][i]) begin
					if (errors < 20) $display("FAIL RX frame %0d byte %0d: %h want %h", p, i, rx_q, erx[h][i]);
					errors++;
				end
			end
			if (mb[5] != 64'(p)) begin $display("FAIL RX_RPTR %0d moved before rx_done (frame %0d)", mb[5], p); errors++; end
			@(negedge clk) rx_done = 1;
			@(negedge clk) rx_done = 0;
			if (rx_avail) begin $display("FAIL rx_avail still 1 after rx_done"); errors++; end
			d = 0;
			while (mb[5] < 64'(p) + 1 && d < 15000) begin @(posedge clk); d++; end
			if (d >= 15000) begin $display("FAIL RX_RPTR not advanced after rx_done (frame %0d, RX_RPTR %0d)", p, mb[5]); errors++; end
			erx_h++; rx_taken++;
		end
	end
end

// ---- helpers -------------------------------------------------------------------
reg [63:0] gen_prev;

// the first eight mailbox accesses since the log was cleared: the start-up
task automatic check_startup(input string what);
	reg [63:0] want [0:7];
	reg [12:0] wa [0:7];
	integer t;
	t = 0;
	while (log_n < 8 && t < 5000) begin @(posedge clk); t++; end
	@(negedge clk);
	wa[0] = 0; want[0] = 0;
	wa[1] = 1; want[1] = log_d[1];
	wa[2] = 2; want[2] = 0;
	wa[3] = 3; want[3] = 0;
	wa[4] = 4; want[4] = 0;
	wa[5] = 5; want[5] = 0;
	wa[6] = 6; want[6] = {|mac, 15'd0, mac};
	wa[7] = 0; want[7] = MAGIC;
	if (log_n < 8) begin $display("FAIL %s: only %0d mailbox accesses", what, log_n); errors++; end
	else for (int i = 0; i < 8; i++)
		if (!log_we[i] || log_a[i] != wa[i] || log_d[i] != want[i]) begin
			$display("FAIL %s: access %0d is %s %h = %h, want write %h = %h", what, i,
			         log_we[i] ? "write" : "read", log_a[i], log_d[i], wa[i], want[i]);
			errors++;
		end
	if (log_n >= 8) begin
		if (log_d[1] == gen_prev) begin $display("FAIL %s: GEN unchanged (%h)", what, log_d[1]); errors++; end
		gen_prev = log_d[1];
	end
	$display("%s: start-up order checked, GEN %h", what, log_d[1]);
endtask

// everything sent has been taken by Main, everything posted taken by the LANCE
task automatic wait_quiet(input string what, input integer limit);
	integer t;
	t = 0;
	while (t < limit && !(etx_h == etx_t && ibx_h == ibx_t && erx_h == erx_t && tx_ready && mb[5] == mb[4] && !rx_avail)) begin
		@(posedge clk); t++;
	end
	if (t >= limit) begin
		$display("FAIL %s: not done after %0d clocks (TX %0d/%0d, inbox %0d/%0d, RX %0d/%0d, RXW %0d RXR %0d)",
		         what, limit, etx_h, etx_t, ibx_h, ibx_t, erx_h, erx_t, mb[4], mb[5]);
		errors++;
	end
	repeat (50) @(posedge clk);
endtask

// ---- the tests -----------------------------------------------------------------
integer i, t0, el, base, taken0, posted0;
initial begin
	// a stale mailbox; Main's hp9k_enet_start() has cleared MAGIC
	for (i = 0; i < 8192; i++) mb[i] = {$urandom, $urandom};
	mb[0] = 0; mb[1] = 64'h1234; mb[2] = 5; mb[3] = 5; mb[4] = 7; mb[5] = 7; mb[6] = 0;
	for (i = 0; i < 16; i++) hdr_t[i] = 0;
	gen_prev = 64'h1234;
	repeat (10) @(negedge clk);
	log_n = 0;
	reset = 0;

	// 1. start-up
	check_startup("power-up");

	// 2. MAC word
	repeat (100) @(negedge clk);
	mac = 48'h0800_09AB_CDEF; mac_stb = 1; @(negedge clk); mac_stb = 0;
	repeat (300) @(negedge clk);
	if (mb[6] != {1'b1, 15'd0, 48'h0800_09AB_CDEF}) begin $display("FAIL MAC word %h after mac_stb", mb[6]); errors++; end
	repeat (6000) @(negedge clk);
	if (main_mac != 48'h0800_09AB_CDEF) begin $display("FAIL Main read MAC %h", main_mac); errors++; end
	mac = 48'd0; mac_stb = 1; @(negedge clk); mac_stb = 0;
	repeat (300) @(negedge clk);
	if (mb[6][63]) begin $display("FAIL MAC word %h: valid with a zero address", mb[6]); errors++; end
	mac = 48'h0800_0912_3456; mac_stb = 1; @(negedge clk); mac_stb = 0;
	repeat (300) @(negedge clk);
	if (mb[6] != {1'b1, 15'd0, 48'h0800_0912_3456}) begin $display("FAIL MAC word %h after mac_stb", mb[6]); errors++; end
	$display("MAC word checked");

	// 3. TX echoed back as RX
	echo = 1;
	send_frame(60, 1, 1);
	send_frame(14, 2, 1);
	send_frame(42, 3, 1);
	send_frame(61, 4, 1);
	send_frame(64, 5, 1);
	send_frame(127, 6, 1);
	send_frame(333, 7, 1);
	send_frame(1000, 8, 1);
	send_frame(1513, 9, 1);
	send_frame(1514, 10, 1);
	wait_quiet("echo", 400_000);
	if (main_tx != 10 || rx_taken != 10) begin $display("FAIL echo: Main took %0d, LANCE got %0d", main_tx, rx_taken); errors++; end
	$display("echo: %0d frames out and back", rx_taken);

	// 4. an RX burst bigger than the ring, one frame too long for the guests
	echo = 0;
	taken0 = rx_taken; posted0 = main_rx_posted;
	main_run = 0;
	for (i = 0; i < 20; i++) inject(i == 5 ? 1600 : i == 9 ? 42 : 60 + i * 37, 100 + i);
	main_run = 1;
	wait_quiet("RX burst", 800_000);
	if (main_rx_posted - posted0 != 16 || main_rx_dropped != 4 || main_rx_skips != 1 || rx_taken - taken0 != 15) begin
		$display("FAIL RX burst: posted %0d dropped %0d skipped %0d taken %0d", main_rx_posted - posted0, main_rx_dropped, main_rx_skips, rx_taken - taken0);
		errors++;
	end
	$display("RX burst: %0d posted, %0d dropped by Main, %0d skipped, %0d taken (paced)", main_rx_posted - posted0, main_rx_dropped, main_rx_skips, rx_taken - taken0);

	// 5. TX ring full: wait until Main takes one
	echo = 1;
	main_run = 0;
	base = int'(mb[2]);
	for (i = 0; i < 8; i++) send_frame(100 + i, 200 + i, 1);
	send_frame(77, 208, 1);
	repeat (8 * TXPOLL) @(negedge clk);
	if (tx_ready || mb[2] != 64'(base + 8)) begin $display("FAIL TX full: tx_ready %0d, TX_WPTR %0d (want %0d)", tx_ready, mb[2], base + 8); errors++; end
	main_run = 1;
	t0 = cyc;
	while (!tx_ready && cyc - t0 < 10_000) @(negedge clk);
	if (!tx_ready) begin $display("FAIL TX full: frame not posted after Main ran"); errors++; end
	wait_quiet("TX full wait", 400_000);
	$display("TX full: waited, then posted");

	// 6. TX ring full and Main gone: dropped after TXWAIT
	main_run = 0;
	base = int'(mb[2]);
	for (i = 0; i < 8; i++) send_frame(90 + i, 300 + i, 1);
	send_frame(66, 308, 0);
	t0 = cyc;
	while (!tx_ready && cyc - t0 < 4 * TXWAIT) @(negedge clk);
	el = cyc - t0;
	if (el < TXWAIT || el > TXWAIT + TXPOLL + 500) begin $display("FAIL TX timeout: tx_ready back after %0d clocks (TXWAIT %0d)", el, TXWAIT); errors++; end
	if (mb[2] != 64'(base + 8)) begin $display("FAIL TX timeout: TX_WPTR %0d, want %0d (frame posted)", mb[2], base + 8); errors++; end
	main_run = 1;
	wait_quiet("TX timeout", 400_000);
	$display("TX timeout: dropped after %0d clocks", el);

	// 7. network Off: TX taken and dropped, RX skipped
	ena = 0;
	base = int'(mb[2]);
	taken0 = rx_taken;
	for (i = 0; i < 3; i++) begin
		send_frame(80 + i, 400 + i, 0);
		t0 = cyc;
		while (!tx_ready && cyc - t0 < 200) @(negedge clk);
		if (!tx_ready) begin $display("FAIL Off: TX frame not dropped at once"); errors++; end
	end
	rx_expect = 0;
	for (i = 0; i < 5; i++) inject(70 + i, 500 + i);
	wait_quiet("Off", 100_000);
	if (mb[2] != 64'(base) || rx_taken != taken0) begin $display("FAIL Off: TX_WPTR %0d (want %0d), frames taken %0d", mb[2], base, rx_taken - taken0); errors++; end
	ena = 1; rx_expect = 1;
	$display("Off: TX dropped, RX skipped");

	// 8. reset landing on a mailbox word in flight
	repeat (100) @(negedge clk);
	while (!(nb_req && !nb_ack)) @(negedge clk);
	reset = 1;
	repeat (20) @(negedge clk);
	log_n = 0;
	reset = 0;
	check_startup("reset");
	t0 = gens_seen;
	repeat (6000) @(negedge clk);
	if (main_gen != gen_prev || gens_seen == t0) begin $display("FAIL Main did not see the new GEN"); errors++; end

	// 9. traffic again after the reset
	echo = 1;
	taken0 = rx_taken;
	for (i = 0; i < 6; i++) send_frame(60 + i * 200, 600 + i, 1);
	for (i = 0; i < 3; i++) inject(100 + i, 700 + i);
	wait_quiet("after reset", 400_000);
	if (rx_taken - taken0 != 9) begin $display("FAIL after reset: %0d frames taken, want 9", rx_taken - taken0); errors++; end
	$display("after reset: %0d frames", rx_taken - taken0);

	$display("cycles %0d, Main TX %0d, RX posted %0d, LANCE took %0d", cyc, main_tx, main_rx_posted, rx_taken);
	if (errors == 0) $display("ALL TESTS PASSED"); else $display("TEST FAILED (%0d)", errors);
	$finish;
end

initial begin
	repeat (6_000_000) @(posedge clk);
	$display("TEST FAILED (bench timeout)");
	$finish;
end
endmodule
