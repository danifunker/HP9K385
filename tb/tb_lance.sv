// Unit bench for rtl/hp98643.sv + rtl/lance.sv (Verilator): the HP 98643A LAN
// card with its Am7990 LANCE.  Written from the specification, not from the
// RTL: docs/reference/lan_98643.md (sections 1, 2, 3, 7.1), MAME's
// am79c90.cpp / hp98643.cpp, and NetBSD's hp300 if_le.c + am7990.c.  Where
// the brief and MAME differ, the brief wins (NOVRAM mirrored every $40 and
// read as {12'hFFF, nibble}, LOOP without INTL = internal loopback, CERR
// never set).
//
// Layers:
//   - a behavioural CPU on the io16 handshake (reg_sel, then reg_cs in the
//     first clock reg_wait is low; reg_dout sampled in the reg_cs clock), with
//     rd16/wr16/rd8/wr8, back-to-back rd32/wr32 halves like hp385_top's
//     S_IO16, and NetBSD's ACK-loop lerdcsr/lewrcsr;
//   - a wire model: a TX sink that captures tx_we bytes and tx_send frames
//     and drops tx_ready for a random time after every frame (and on demand),
//     and an RX source that offers frames with a correct FCS (CRC-32 computed
//     here) on rx_avail/rx_len/rx_addr/rx_q until rx_done.
//
// Tests:
//   a  boot ROM register test (sub_0e784, brief 2.1 steps 1-11), plus the
//      status byte, ACK and card-reset semantics and the ROM's RAM test
//   b  NOVRAM: MAC, checksum, $FFFx reads, mirrors, 64 writable nibbles, recall on card reset
//   c  boot ROM loopback cases 1-6 (sub_0e88e, brief 2.2) with the exact
//      template, plus a bad software FCS under DTCR and external loopback
//   d  NetBSD attach/init/transmit/receive/interrupt sequence with every
//      RAP/RDP access through the ACK loop
//   e  rings: TX/RX chaining, odd buffers, errors, MISS, wrap at 1/2/8/128,
//      BSWP, STOP priority, CSR1-3 write protection, RAP, DTCR on the wire
//
// Run: scripts/run_benches.sh lance
//   or verilator --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_lance
//      --Mdir build/obj_tb_lance -o tb tb/tb_lance.sv rtl/hp98643.sv rtl/lance.sv
//      && build/obj_tb_lance/tb
`timescale 1ns/1ps
module tb_lance;

localparam [47:0] MAC      = 48'h08_00_09_38_A5_C3;   // not the RTL default, so the parameter is checked
localparam        POLL     = 1500;                    // TX poll period (clocks)
localparam        IDON_DLY = 40;

reg clk = 0, reset = 1;
always #15 clk = !clk;

// ---------------------------------------------------------------- DUT ----
reg         reg_sel = 0, reg_cs = 0, reg_we = 0;
reg  [15:1] reg_off = 0;
reg   [1:0] reg_be = 0;
reg  [15:0] reg_din = 0;
wire [15:0] reg_dout;
wire        reg_wait, irq;
reg         tx_ready = 1;
wire        tx_we, tx_send;
wire [10:0] tx_addr, tx_len;
wire  [7:0] tx_wdata;
reg         rx_avail = 0;
reg  [10:0] rx_len = 0;
wire [10:0] rx_addr;
reg   [7:0] rx_q = 0;
wire        rx_done;
wire [47:0] padr;
wire        padr_stb;

hp98643 #(.MAC(MAC), .POLL(POLL), .IDON_DLY(IDON_DLY)) dut (
	.clk(clk), .reset(reset),
	.reg_sel(reg_sel), .reg_cs(reg_cs), .reg_we(reg_we), .reg_off(reg_off), .reg_be(reg_be),
	.reg_din(reg_din), .reg_dout(reg_dout), .reg_wait(reg_wait), .irq(irq),
	.tx_ready(tx_ready), .tx_we(tx_we), .tx_addr(tx_addr), .tx_wdata(tx_wdata),
	.tx_send(tx_send), .tx_len(tx_len),
	.rx_avail(rx_avail), .rx_len(rx_len), .rx_addr(rx_addr), .rx_q(rx_q), .rx_done(rx_done),
	.padr(padr), .padr_stb(padr_stb));

// ------------------------------------------------------------ checking ----
integer errors = 0;
string  test = "";

task automatic chk(input bit ok, input string what);
	if (!ok) begin
		errors++;
		if (errors <= 80) $display("FAIL [%s] %s  (t=%0t)", test, what, $time);
	end
endtask

// ------------------------------------------------------- register map ----
localparam [15:0] A_ID = 16'h0000, A_STAT = 16'h0003, A_RDP = 16'h4000, A_RAP = 16'h4002;
localparam [15:0] ERR  = 16'h8000, BABL = 16'h4000, CERR = 16'h2000, MISS = 16'h1000,
                  MERR = 16'h0800, RINT = 16'h0400, TINT = 16'h0200, IDON = 16'h0100,
                  INTR = 16'h0080, INEA = 16'h0040, RXON = 16'h0020, TXON = 16'h0010,
                  TDMD = 16'h0008, STOP = 16'h0004, STRT = 16'h0002, INIT = 16'h0001;

// ------------------------------------------------------ behavioural CPU ----
// Every task starts and ends 1 ns after a rising edge.  reg_sel and the
// access are set up, reg_wait is sampled after it settles, and reg_cs is
// raised in the first clock reg_wait is low (as hp385_top's io16_cs does);
// reg_dout is sampled in that clock and the access commits at its end.
integer cpu_gap = 2;      // idle clocks between accesses
integer max_wait = 0;     // longest reg_wait seen

// The access itself runs in one server process (cpu_srv), so Verilator,
// which inlines tasks, does not copy the handshake into every call site.
bit         cq_req = 0, cq_we = 0, cq_hold = 0;
reg  [15:0] cq_a = 0, cq_d = 0, cq_q = 0;
reg   [1:0] cq_be = 0;

task automatic bus(input bit we, input [15:0] a, input [1:0] be, input [15:0] d,
                   output [15:0] q, input bit hold);
	cq_we = we; cq_a = a; cq_be = be; cq_d = d; cq_hold = hold;
	cq_req = 1;
	wait (!cq_req);
	q = cq_q;
endtask

initial forever begin
	integer n;
	wait (cq_req);
	reg_sel = 1; reg_we = cq_we; reg_off = cq_a[15:1]; reg_be = cq_be; reg_din = cq_d; reg_cs = 0;
	#2;
	n = 0;
	while (reg_wait && n < 100) begin @(posedge clk); #2; n++; end
	chk(!reg_wait, $sformatf("reg_wait stuck high on %s +$%h", cq_we ? "write" : "read", cq_a));
	if (n > max_wait) max_wait = n;
	reg_cs = 1;
	#2;
	chk(!reg_wait, $sformatf("reg_wait rose with reg_cs (+$%h)", cq_a));
	cq_q = reg_dout;
	@(posedge clk); #1;
	reg_cs = 0;
	if (!cq_hold) begin
		reg_sel = 0; reg_we = 0;
		repeat (cpu_gap) @(posedge clk);
		#1;
	end
	cq_req = 0;
end

task automatic wr16(input [15:0] a, input [15:0] d);
	reg [15:0] q; bus(1, a, 2'b11, d, q, 0);
endtask
task automatic rd16(input [15:0] a, output [15:0] q);
	bus(0, a, 2'b11, 16'h0, q, 0);
endtask
task automatic wr8(input [15:0] a, input [7:0] d);
	reg [15:0] q; bus(1, a, a[0] ? 2'b01 : 2'b10, {d, d}, q, 0);
endtask
task automatic rd8(input [15:0] a, output [7:0] q);
	reg [15:0] w; bus(0, a, a[0] ? 2'b01 : 2'b10, 16'h0, w, 0);
	q = a[0] ? w[7:0] : w[15:8];
endtask
// longword: high half at a, low half at a+2, back to back with reg_sel held
task automatic rd32(input [15:0] a, output [31:0] q);
	reg [15:0] h, l; bus(0, a, 2'b11, 16'h0, h, 1); bus(0, a + 16'd2, 2'b11, 16'h0, l, 0);
	q = {h, l};
endtask
task automatic wr32(input [15:0] a, input [31:0] d);
	reg [15:0] q; bus(1, a, 2'b11, d[31:16], q, 1); bus(1, a + 16'd2, 2'b11, d[15:0], q, 0);
endtask

// LANCE CSR access, ROM style (no ACK poll)
task automatic csr_w_impl(input [1:0] n, input [15:0] d); wr16(A_RAP, n); wr16(A_RDP, d); endtask
task automatic csr_r_impl(input [1:0] n, output [15:0] q); wr16(A_RAP, n); rd16(A_RDP, q); endtask

// NetBSD lewrcsr/lerdcsr: every RAP write and RDP access repeats until
// status & LE_ACK.  (Bounded at 10 tries; ACK must come.)
task automatic nb_wrcsr_impl(input [15:0] port, input [15:0] d);
	reg [7:0] st; integer t;
	t = 0; do begin wr16(A_RAP, port); rd8(A_STAT, st); t++; end while (!st[2] && t < 10);
	chk(st[2], "lewrcsr: no ACK after RAP write");
	t = 0; do begin wr16(A_RDP, d); rd8(A_STAT, st); t++; end while (!st[2] && t < 10);
	chk(st[2], "lewrcsr: no ACK after RDP write");
endtask
task automatic nb_rdcsr_impl(input [15:0] port, output [15:0] q);
	reg [7:0] st; integer t;
	t = 0; do begin wr16(A_RAP, port); rd8(A_STAT, st); t++; end while (!st[2] && t < 10);
	chk(st[2], "lerdcsr: no ACK after RAP write");
	t = 0; do begin rd16(A_RDP, q); rd8(A_STAT, st); t++; end while (!st[2] && t < 10);
	chk(st[2], "lerdcsr: no ACK after RDP read");
	chk((q & (CERR | MERR)) == 0, $sformatf("CSR0 %h has CERR or MERR", q));
endtask

// poll CSR0 (sets RAP = 0 first) until any bit of mask, at most maxr reads
task automatic wait_csr0_impl(input [15:0] mask, input integer maxr, output [15:0] q);
	integer t;
	wr16(A_RAP, 0);
	t = 0; do begin rd16(A_RDP, q); t++; end while (!(q & mask) && t < maxr);
	chk((q & (CERR | MERR)) == 0, $sformatf("CSR0 %h has CERR or MERR", q));
endtask

// card RAM by LANCE address (bits 23:14 ignored by the card)
function automatic [15:0] hb(input [23:0] la); hb = {2'b10, la[13:0]}; endfunction
task automatic mw16(input [23:0] la, input [15:0] d); wr16(hb(la), d); endtask
task automatic mr16(input [23:0] la, output [15:0] q); rd16(hb(la), q); endtask
task automatic mw8(input [23:0] la, input [7:0] d); wr8(hb(la), d); endtask
task automatic mr8(input [23:0] la, output [7:0] q); rd8(hb(la), q); endtask
task automatic fill_impl(input [23:0] la, input integer nbytes, input [15:0] w);
	for (integer i = 0; i < nbytes; i += 2) mw16(la + i, w);
endtask

// ------------------------------------------------------- frames, CRC ----
reg [7:0] fb [0:2047];    // frame under construction
integer   fl = 0;

function automatic [31:0] crc_upd(input [31:0] c, input [7:0] b);
	reg [31:0] r;
	r = c ^ {24'h0, b};
	for (int k = 0; k < 8; k++) r = r[0] ? (r >> 1) ^ 32'hEDB88320 : r >> 1;
	return r;
endfunction
function automatic [31:0] fcs_of(input integer n);       // Ethernet FCS of fb[0..n-1]
	reg [31:0] c;
	c = 32'hFFFFFFFF;
	for (int i = 0; i < n; i++) c = crc_upd(c, fb[i]);
	return ~c;
endfunction
function automatic [5:0] mhash(input [47:0] a);          // ether_crc32_le(a, 6) >> 26
	reg [31:0] c;
	c = 32'hFFFFFFFF;
	for (int i = 0; i < 6; i++) c = crc_upd(c, a[47 - 8 * i -: 8]);
	return c[31:26];
endfunction

task automatic mkframe(input [47:0] dst, input [47:0] src, input integer n, input integer seed);
	for (int i = 0; i < 6; i++) begin fb[i] = dst[47 - 8 * i -: 8]; fb[6 + i] = src[47 - 8 * i -: 8]; end
	fb[12] = 8'h08; fb[13] = 8'h00;
	for (int i = 14; i < n; i++) fb[i] = 8'(seed * 37 + i * 11 + (i >> 3) + (seed >> 2));
	fl = n;
endtask
task automatic add_fcs();
	reg [31:0] f;
	f = fcs_of(fl);
	fb[fl] = f[7:0]; fb[fl + 1] = f[15:8]; fb[fl + 2] = f[23:16]; fb[fl + 3] = f[31:24];
	fl += 4;
endtask

// Frame byte k of a LANCE buffer at address a is card-RAM byte a+k with
// BSWP = 1 (host even byte = D15:8), and byte (a+k)^1 with BSWP = 0.
task automatic put_bytes_impl(input [23:0] a, input integer from, input integer n, input bit bswp, input bit bytes_only);
	integer k; reg [23:0] la;
	k = 0;
	while (k < n) begin
		la = a + k;
		if (!la[0] && k + 1 < n && !bytes_only) begin
			mw16(la, bswp ? {fb[from + k], fb[from + k + 1]} : {fb[from + k + 1], fb[from + k]});
			k += 2;
		end else begin
			mw8(bswp ? la : la ^ 24'd1, fb[from + k]);
			k++;
		end
	end
endtask
task automatic chk_buf_impl(input [23:0] a, input integer from, input integer n, input bit bswp, input string what);
	integer k, bad, first; reg [23:0] la; reg [15:0] q; reg [7:0] g [0:1]; reg [7:0] fg, fw; integer m;
	k = 0; bad = 0; first = -1; fg = 0; fw = 0;
	while (k < n) begin
		la = a + k;
		if (!la[0] && k + 1 < n) begin
			mr16(la, q);
			g[0] = bswp ? q[15:8] : q[7:0]; g[1] = bswp ? q[7:0] : q[15:8]; m = 2;
		end else begin
			mr8(bswp ? la : la ^ 24'd1, g[0]); m = 1;
		end
		for (int j = 0; j < m; j++) if (g[j] !== fb[from + k + j]) begin
			if (first < 0) begin first = k + j; fg = g[j]; fw = fb[from + k + j]; end
			bad++;
		end
		k += m;
	end
	chk(bad == 0, $sformatf("%s: %0d of %0d bytes differ, first at %0d: %h want %h", what, bad, n, first, fg, fw));
endtask
task automatic chk_host8_impl(input [23:0] la, input [7:0] want, input string what);
	reg [7:0] g; mr8(la, g);
	chk(g == want, $sformatf("%s: card RAM byte $%h = %h, want %h (untouched)", what, la[13:0], g, want));
endtask

// descriptors: 4 words at ring + 8*i; word 1 (OWN) written last
reg [15:0] md [0:3];
task automatic wmd_impl(input [23:0] ring, input integer i, input [23:0] buffer, input [15:0] bits,
                   input integer bcnt, input [15:0] w3);
	reg [23:0] d; d = ring + 8 * i;
	mw16(d, buffer[15:0]);
	mw16(d + 4, 16'hF000 | (16'(-bcnt) & 16'h0FFF));
	mw16(d + 6, w3);
	mw16(d + 2, bits | {8'h0, buffer[23:16]});
endtask
task automatic rmd_impl(input [23:0] ring, input integer i);
	reg [23:0] d; d = ring + 8 * i;
	for (int j = 0; j < 4; j++) mr16(d + 2 * j, md[j]);
endtask
// the LANCE writes only words 1 and 3: LADR and BCNT must be as written
task automatic chk_md_fixed_impl(input [23:0] ring, input integer i, input [23:0] buffer, input integer bcnt, input string what);
	rmd(ring, i);
	chk(md[0] == buffer[15:0], $sformatf("%s: descriptor %0d word 0 (LADR) is %h, want %h", what, i, md[0], buffer[15:0]));
	chk(md[1][7:0] == buffer[23:16], $sformatf("%s: descriptor %0d HADR is %h, want %h", what, i, md[1][7:0], buffer[23:16]));
	chk(md[2] == (16'hF000 | (16'(-bcnt) & 16'h0FFF)), $sformatf("%s: descriptor %0d word 2 (BCNT) is %h", what, i, md[2]));
endtask

// ------------------------------------------------------- wire: TX sink ----
reg   [7:0] txb   [0:2047];
reg   [7:0] txcap [0:15][0:2047];
integer     txcap_len [0:15];
integer     tx_count = 0;
integer     tx_busy = 0;      // clocks left with tx_ready low after a frame
bit         tx_hold = 0;      // a test holds tx_ready low
integer     tx_we_n = 0;
always @(posedge clk) begin
	if (tx_we) begin
		if (!tx_ready) chk(0, $sformatf("tx_we (addr %0d) while tx_ready is low", tx_addr));
		txb[tx_addr] = tx_wdata;
		tx_we_n++;
	end
	if (tx_send) begin
		if (!tx_ready) chk(0, "tx_send while tx_ready is low");
		for (int i = 0; i < 2048; i++) txcap[tx_count % 16][i] = txb[i];
		txcap_len[tx_count % 16] = tx_len;
		tx_count++;
		tx_busy = 4 + $urandom % 300;
	end else if (tx_busy > 0) tx_busy--;
	tx_ready <= !tx_hold && tx_busy == 0 && !tx_send;
end

task automatic wait_tx(input integer cnt, input integer maxclk);
	integer k; k = 0;
	while (tx_count < cnt && k < maxclk) begin @(posedge clk); #1; k++; end
endtask
task automatic chk_tx(input integer idx, input integer n, input string what);
	integer bad, first; bad = 0; first = -1;
	chk(txcap_len[idx % 16] == n, $sformatf("%s: tx_len %0d, want %0d", what, txcap_len[idx % 16], n));
	for (int i = 0; i < n; i++) if (txcap[idx % 16][i] !== fb[i]) begin if (first < 0) first = i; bad++; end
	chk(bad == 0, $sformatf("%s: %0d wire bytes differ, first at %0d: %h want %h", what, bad, first,
		first >= 0 ? txcap[idx % 16][first] : 8'h0, first >= 0 ? fb[first] : 8'h0));
endtask

// ----------------------------------------------------- wire: RX source ----
reg   [7:0] rxb [0:2047];
integer     rx_taken = 0;
bit         rx_go = 0;
integer     rx_go_len = 0;
always @(posedge clk) rx_q <= rxb[rx_addr];
always @(posedge clk) begin
	if (rx_done) begin
		if (!rx_avail) chk(0, "rx_done while rx_avail is low");
		rx_avail <= 0;
		rx_taken++;
	end else if (rx_go && !rx_avail) begin
		rx_avail <= 1;
		rx_len   <= rx_go_len;
	end
end
// offer fb[0..fl-1] (FCS included) and wait until the card is done with it
task automatic offer();
	integer t0, k;
	t0 = rx_taken;
	for (int i = 0; i < fl; i++) rxb[i] = fb[i];
	rx_go_len = fl; rx_go = 1;
	@(posedge clk); #1;
	rx_go = 0;
	k = 0;
	while (rx_taken == t0 && k < 20000) begin @(posedge clk); #1; k++; end
	chk(rx_taken != t0, $sformatf("wire frame of %0d bytes never finished (no rx_done)", fl));
endtask

// ------------------------------------------------------- PADR monitor ----
reg  [47:0] last_padr = 0;
integer     padr_cnt = 0;
always @(posedge clk) if (padr_stb) begin last_padr <= padr; padr_cnt <= padr_cnt + 1; end

// =======================================================================
// a. Boot ROM register test (sub_0e784) + status/ACK/reset + RAM test
// =======================================================================
function automatic [15:0] pat(input integer i); pat = 16'(i * 40503 + 16'h5A5A) ^ 16'(i >> 3); endfunction

task automatic test_rom_regs();
	reg [15:0] q; reg [7:0] st; reg [31:0] l; integer t, bad; bit ok;
	test = "a ROM register test"; cpu_gap = 8;
	rd16(A_ID, q);
	chk(q == 16'h0015, $sformatf("ID reads %h, want 0015", q));
	// 1
	wr8(A_STAT, 8'h00); rd8(A_STAT, st);
	chk((st & 8'h88) == 0, $sformatf("step 1: status %h, & $88 must be 0", st));
	// 2
	wr8(A_STAT, 8'h08); rd8(A_STAT, st);
	chk(st[3], $sformatf("step 2: status %h, LOCK not set", st));
	// 3 (sub_0ea04)
	ok = 0;
	for (t = 0; t < 10 && !ok; t++) begin wr16(A_RAP, 0); rd8(A_STAT, st); ok = st[2]; end
	chk(ok, "step 3: no ACK within 10 RAP writes (ROM code $22)");
	wr16(A_RDP, 16'h0004); rd16(A_RDP, q);
	chk(q == 16'h0004, $sformatf("step 3: CSR0 reads %h after STOP, want 0004", q));
	// 4
	rd8(A_STAT, st);
	chk((st & 8'h0C) == 8'h0C, $sformatf("step 4: status %h, & $0C must be $0C", st));
	// 5
	rd16(A_RDP, q);
	chk(q == 16'h0004, $sformatf("step 5: RDP reads %h, want 0004", q));
	wr16(A_RDP, 16'h0002);                    // STRT with no INIT
	// 6
	wr16(A_ID, 16'h0001);
	rd8(A_STAT, st);
	chk((st & 8'hCC) == 0, $sformatf("step 6: status %h after card reset, & $CC must be 0", st));
	chk(st == 8'h21, $sformatf("status %h after card reset, want 21 (level 5, bit 0 set)", st));
	// 7 (no ACK poll)
	rd16(A_RDP, q);
	chk(q == 16'h0004, $sformatf("step 7: CSR0 reads %h right after the card reset, want 0004", q));
	// 8
	for (int r = 3; r >= 0; r--) begin
		wr16(A_RAP, r); rd16(A_RAP, q);
		chk(q[1:0] == r, $sformatf("step 8: RAP reads %h after writing %0d", q, r));
	end
	// 9
	wr16(A_RAP, 1); wr16(A_RDP, 16'h0000); rd16(A_RDP, q);
	chk(q == 16'h0000, $sformatf("step 9: CSR1 reads %h, want 0000", q));
	wr16(A_RDP, 16'hFFFE); rd16(A_RDP, q);
	chk(q == 16'hFFFE, $sformatf("step 9: CSR1 reads %h, want FFFE", q));
	// 10
	wr16(A_RAP, 2); wr16(A_RDP, 16'h00FF); rd16(A_RDP, q);
	chk(q[7:0] == 8'hFF, $sformatf("step 10: CSR2 reads %h, want low byte FF", q));
	wr16(A_RDP, 16'h0000); rd16(A_RDP, q);
	chk(q[7:0] == 8'h00, $sformatf("step 10: CSR2 reads %h, want low byte 00", q));
	// 11
	wr16(A_RAP, 3); wr16(A_RDP, 16'h0007); rd16(A_RDP, q);
	chk(q[2:0] == 3'd7, $sformatf("step 11: CSR3 reads %h, want bits 2:0 = 7", q));
	wr16(A_RDP, 16'h0000); rd16(A_RDP, q);
	chk(q[2:0] == 3'd0, $sformatf("step 11: CSR3 reads %h, want bits 2:0 = 0", q));

	// ---- status byte and ACK details (brief 1.2) ----
	test = "a status/ACK/reset";
	wr8(16'h0001, 8'hFF);                     // NetBSD-style byte reset
	rd8(A_STAT, st); chk(st == 8'h21, $sformatf("status %h after byte reset at +1, want 21", st));
	wr8(A_STAT, 8'h00); rd8(A_STAT, st);
	chk(!st[2], $sformatf("status %h: ACK set by a write with LOCK = 0", st));
	rd16(A_RAP, q); rd8(A_STAT, st);
	chk(st[2], $sformatf("status %h: ACK not set by a RAP read", st));
	wr8(A_STAT, 8'h00); rd8(A_STAT, st);
	chk(st[2], $sformatf("status %h: ACK cleared by a status write (only reset may)", st));
	wr16(A_ID, 16'h0000); rd8(A_STAT, st);
	chk(!st[2], "ACK survives a card reset");
	wr16(A_RDP, 16'h0004); rd8(A_STAT, st);   // RDP write
	chk(st[2], "ACK not set by an RDP write");
	wr16(A_ID, 16'h0000);
	rd16(A_RDP, q); rd8(A_STAT, st);
	chk(st[2], "ACK not set by an RDP read");
	wr16(A_ID, 16'h0000);
	wr8(A_STAT, 8'hFF); rd8(A_STAT, st);      // read-only bits ignored
	chk(st == 8'hAD, $sformatf("status %h after writing FF, want AD (IE LOCK ACK, level 5, bit 0)", st));
	chk(!irq, "irq with IE set but the LANCE stopped");
	csr_w(3, 16'h0004); wr16(A_RAP, 2);
	wr16(A_ID, 16'h0000);
	rd8(A_STAT, st); chk(st == 8'h21, $sformatf("status %h after reset, want 21 (IE/LOCK/ACK cleared)", st));
	rd16(A_RAP, q);  chk(q[1:0] == 0, $sformatf("RAP %h after card reset, want 0", q));
	csr_r(3, q);     chk(q == 16'h0000, $sformatf("CSR3 %h after card reset, want 0", q));
	csr_r(0, q);     chk(q == 16'h0004, $sformatf("CSR0 %h after card reset, want 0004", q));
	wr16(A_ID, 16'h0000);

	// ---- the ROM's ram_test_range over +$8000-$BFFF ----
	test = "a RAM test"; cpu_gap = 1;
	for (int i = 0; i < 8192; i++) wr16(16'h8000 + 16'(2 * i), pat(i));
	bad = 0;
	for (int i = 0; i < 8192; i++) begin
		rd16(16'h8000 + 16'(2 * i), q);
		if (q !== pat(i)) begin
			if (bad < 3) chk(0, $sformatf("RAM word +$%h reads %h, want %h", 16'h8000 + 16'(2 * i), q, pat(i)));
			bad++;
		end
	end
	chk(bad <= 3, $sformatf("%0d RAM words wrong in all", bad));
	// byte lanes
	wr16(16'h8010, 16'h1234); wr8(16'h8010, 8'hAB); rd16(16'h8010, q);
	chk(q == 16'hAB34, $sformatf("even byte write: %h, want AB34", q));
	wr8(16'h8011, 8'hCD); rd16(16'h8010, q);
	chk(q == 16'hABCD, $sformatf("odd byte write: %h, want ABCD", q));
	rd8(16'h8011, st); chk(st == 8'hCD, $sformatf("odd byte read %h", st));
	rd8(16'h8010, st); chk(st == 8'hAB, $sformatf("even byte read %h", st));
	// longwords: back-to-back halves at different addresses (hp385_top S_IO16)
	wr32(16'h8100, 32'hDEADBEEF); rd32(16'h8100, l);
	chk(l == 32'hDEADBEEF, $sformatf("long write/read %h", l));
	rd16(16'h8100, q); chk(q == 16'hDEAD, $sformatf("long write high half %h", q));
	rd16(16'h8102, q); chk(q == 16'hBEEF, $sformatf("long write low half %h", q));
	bad = 0;
	for (int i = 1024; i < 1088; i += 2) begin
		rd32(16'h8000 + 16'(2 * i), l);
		if (l !== {pat(i), pat(i + 1)}) bad++;
	end
	chk(bad == 0, $sformatf("%0d of 32 back-to-back long reads wrong", bad));
	// a register read right after a RAM read (different wait behaviour)
	rd16(16'h8010, q); rd16(A_ID, q);
	chk(q == 16'h0015, $sformatf("ID after RAM read %h", q));
	cpu_gap = 8;
	wr16(A_ID, 16'h0001);
endtask

// =======================================================================
// b. NOVRAM
// =======================================================================
task automatic test_novram();
	reg [15:0] hi, lo, q; reg [7:0] nb [0:15]; reg [15:0] w [0:31]; reg [7:0] sum, b;
	test = "b NOVRAM"; cpu_gap = 2;
	for (int i = 0; i < 32; i++) begin
		rd16(16'hC000 + 16'(2 * i), w[i]);
		chk(w[i][15:4] == 12'hFFF, $sformatf("NOVRAM word +$%h reads %h, want FFFx", 16'hC000 + 16'(2 * i), w[i]));
	end
	for (int n = 0; n < 16; n++) nb[n] = {w[2 * n][3:0], w[2 * n + 1][3:0]};
	for (int k = 0; k < 6; k++)
		chk(nb[2 + k] == MAC[47 - 8 * k -: 8], $sformatf("NOVRAM byte %0d = %h, want MAC byte %h", 2 + k, nb[2 + k], MAC[47 - 8 * k -: 8]));
	sum = 0;
	for (int n = 1; n <= 14; n++) sum += nb[n];
	chk(nb[15] == sum, $sformatf("NOVRAM checksum byte 15 = %h, want %h (sum of bytes 1-14)", nb[15], sum));
	$display("  NOVRAM bytes: %h %h %h %h %h %h %h %h  %h %h %h %h %h %h %h %h",
		nb[0], nb[1], nb[2], nb[3], nb[4], nb[5], nb[6], nb[7], nb[8], nb[9], nb[10], nb[11], nb[12], nb[13], nb[14], nb[15]);
	// mirrors every $40 across +$C000-$FFFF
	for (int m = 0; m < 6; m++) begin
		reg [15:0] base;
		base = (m == 0) ? 16'hC040 : (m == 1) ? 16'hC080 : (m == 2) ? 16'hD000 :
		       (m == 3) ? 16'hE7C0 : (m == 4) ? 16'hF040 : 16'hFFC0;
		for (int i = 0; i < 32; i++) begin
			rd16(base + 16'(2 * i), q);
			chk(q == w[i], $sformatf("NOVRAM mirror +$%h reads %h, want %h", base + 16'(2 * i), q, w[i]));
		end
	end
	// NetBSD's byte reads at odd offsets
	rd8(16'hC009, b); chk(b == {4'hF, nb[2][7:4]}, $sformatf("byte read +$C009 = %h", b));
	rd8(16'hC00B, b); chk(b == {4'hF, nb[2][3:0]}, $sformatf("byte read +$C00B = %h", b));
	// HP-UX's self-test (_hw_int_test, memory test on +$C000, 128 bytes):
	// 64 distinct writable nibbles, mirrored every $80; then the card reset
	// recalls the image (NOVRAM EEPROM recall)
	for (int i = 0; i < 64; i++) wr16(16'hC000 + 16'(2 * i), 16'(i * 7 + 3));
	for (int i = 0; i < 64; i++) begin
		rd16(16'hC000 + 16'(2 * i), q);
		chk(q == {12'hFFF, 4'(i * 7 + 3)}, $sformatf("NOVRAM nibble %0d after write = %h", i, q));
		rd16(16'hD080 + 16'(2 * i), q);
		chk(q == {12'hFFF, 4'(i * 7 + 3)}, $sformatf("NOVRAM mirror +$D080 nibble %0d after write = %h", i, q));
	end
	wr8(16'hC00D, 8'h0A); rd16(16'hC00C, q); chk(q == 16'hFFFA, $sformatf("NOVRAM byte write +$C00D: %h", q));
	wr16(16'h0000, 16'h0001);                         // card reset: recall
	for (int i = 0; i < 64; i++) begin
		rd16(16'hC000 + 16'(2 * i), q);
		chk(q == w[i % 32], $sformatf("NOVRAM nibble %0d after card reset = %h, want %h", i, q, w[i % 32]));
	end
endtask

// =======================================================================
// c. Boot ROM loopback test (sub_0e88e)
// =======================================================================
integer lb_tx_start;

task automatic rom_handshake();                  // LOCK, then sub_0ea04
	reg [7:0] st; bit ok;
	wr8(A_STAT, 8'h08);
	ok = 0;
	for (int t = 0; t < 10 && !ok; t++) begin wr16(A_RAP, 0); rd8(A_STAT, st); ok = st[2]; end
	chk(ok, "ACK/STOP handshake: no ACK");
	wr16(A_RDP, STOP);
endtask

// cs 1-6: the ROM's cases.  7: case 2 with a wrong software FCS.
// 8: the external test's MODE $0004 (LOOP without INTL) with the NOVRAM MAC.
task automatic rom_lb_case(input integer cs);
	reg [15:0] mode, q, rmd1, rmd3, tmd1, tmd3; reg [7:0] st;
	reg [47:0] dst, pa; reg [31:0] f;
	integer bcnt, ncmp, n, rints; bit coll, ladrf3, badfcs, ext;
	test = $sformatf("c loopback case %0d", cs);
	coll = 0; ladrf3 = 0; badfcs = 0; ext = 0; pa = 48'h14_02_36_25_58_47; dst = pa;
	case (cs)
	1: begin mode = 16'h0044; bcnt = 28; ncmp = 32; end
	2: begin mode = 16'h004C; bcnt = 32; ncmp = 32; end
	3: begin mode = 16'h8044; bcnt = 28; ncmp = 28; dst = 48'h51_04_36_25_58_47; end
	4: begin mode = 16'h004C; bcnt = 32; ncmp = 28; dst = 48'h51_04_36_25_58_47; ladrf3 = 1; end
	5: begin mode = 16'h0044; bcnt = 28; ncmp = 28; dst = 48'hFF_FF_FF_FF_FF_FF; end
	6: begin mode = 16'h0054; bcnt = 28; ncmp = 0;  coll = 1; end
	7: begin mode = 16'h004C; bcnt = 32; ncmp = 28; badfcs = 1; end
	8: begin mode = 16'h0004; bcnt = 28; ncmp = 32; ext = 1; pa = MAC; dst = MAC; end
	endcase
	// the frame: dst, 00:01:02:03:04:05, 06..0F, 11..16 (28 bytes), FCS
	for (int i = 0; i < 6; i++) fb[i] = dst[47 - 8 * i -: 8];
	for (int i = 6; i < 16; i++) fb[i] = 8'(i - 6);
	for (int i = 16; i < 22; i++) fb[i] = 8'(i - 6);
	for (int i = 22; i < 28; i++) fb[i] = 8'(i - 22 + 8'h11);
	fl = 28; add_fcs();
	if (cs == 1) chk(fcs_of(28) == 32'hB09F7B44, "BENCH: case-1 FCS is not B09F7B44 (bench CRC wrong)");
	if (cs == 4) chk(fcs_of(28) == 32'h66DB68AA, "BENCH: case-4 FCS is not AA 68 DB 66 (bench CRC wrong)");
	if (cs == 4) chk(mhash(dst) == 3, "BENCH: hash of 51:04:36:25:58:47 is not 3");
	if (badfcs) fb[31] = fb[31] ^ 8'h01;

	// setup (sub_0eb34)
	rom_handshake();
	wr8(A_STAT, 8'h00);                                    // IE stays 0
	mw16(24'h8000, mode);
	mw16(24'h8002, {pa[39:32], pa[47:40]});                // $0214 $2536 $4758 for 14:02:36:25:58:47
	mw16(24'h8004, {pa[23:16], pa[31:24]});
	mw16(24'h8006, {pa[7:0], pa[15:8]});
	mw16(24'h8008, ladrf3 ? 16'h0008 : 16'h0000);           // byte +$09 = $08: LADRF bit 3
	mw16(24'h800A, 0); mw16(24'h800C, 0); mw16(24'h800E, 0);
	mw16(24'h8010, 16'h8018); mw16(24'h8012, 16'h0000);    // RDRA, RLEN 0
	mw16(24'h8014, 16'h8020); mw16(24'h8016, 16'h0000);    // TDRA, TLEN 0
	mw16(24'h8018, 16'h8048); mw16(24'h801A, 16'h8000); mw16(24'h801C, 16'hFFE0); mw16(24'h801E, 16'h0000);
	mw16(24'h8020, 16'h8028); mw16(24'h8022, 16'h8300); mw16(24'h8024, 16'h0000); mw16(24'h8026, 16'h0000);
	put_bytes(24'h8028, 0, 32, 1, 0);                      // frame + FCS at +$28..+$47
	fill(24'h8048, 32, 16'hEEEE);                          // RX buffer
	fill(24'h8068, 8, 16'hEEEE);                           // guard after it
	mw16(24'h8024, 16'hF000 | (16'(-bcnt) & 16'h0FFF));    // then TMD2
	wr16(A_RAP, 1); wr16(A_RDP, 16'h8000);
	wr16(A_RAP, 2); wr16(A_RDP, 16'h0000);
	wr16(A_RAP, 3); wr16(A_RDP, 16'h0004);
	lb_tx_start = tx_count;
	wr16(A_RAP, 0); wr16(A_RDP, 16'h004B);                 // INEA | TDMD | STRT | INIT

	// poll (sub_0ea9e) 1: CSR0 until ACK and IDON
	n = 0;
	do begin rd16(A_RDP, q); rd8(A_STAT, st); n++; end while (!(st[2] && q[8]) && n < 300);
	chk(q[8], $sformatf("no IDON (CSR0 %h)", q));
	// 2: IP already set (IE = 0: IP is raw)
	rd8(A_STAT, st);
	chk(st[6], $sformatf("status %h: IP not set when IDON is seen (ROM code $12)", st));
	chk(!irq, "irq asserted with IE = 0");
	chk(last_padr == pa, $sformatf("padr %h, want %h", last_padr, pa));
	// 3: CSR0 until TINT
	n = 0;
	while (!q[9] && n < 300) begin rd16(A_RDP, q); n++; end
	chk(q[9], $sformatf("no TINT (CSR0 %h)", q));
	chk(!(q & CERR), "CERR set in loopback");
	// 4: RMD1 and TMD3
	mr16(24'h8026, tmd3);
	if (coll) begin
		chk(tmd3[10], $sformatf("forced collision: TMD3 %h, RTRY (bit 10) not set", tmd3));
		chk(!q[15], $sformatf("forced collision: CSR0.ERR set (%h)", q));
		for (int i = 0; i < 40; i++) begin rd16(A_RDP, q); chk(!q[10], "forced collision: RINT set (no receive allowed)"); if (q[10]) break; end
		chk(!q[15], $sformatf("forced collision: CSR0.ERR set later (%h)", q));
		mr16(24'h8022, tmd1);
		chk(tmd1[15:8] == 8'h43, $sformatf("forced collision: TMD1 %h, want OWN clear, ERR|STP|ENP", tmd1));
		mr16(24'h801A, rmd1);
		chk(rmd1 == 16'h8000, $sformatf("forced collision: RMD1 changed to %h", rmd1));
		chk_host8(24'h8048, 8'hEE, "forced collision: RX buffer written");
	end else begin
		chk(!tmd3[10], $sformatf("TMD3 %h has RTRY", tmd3));
		// 5: RINT within 30 CSR0 reads
		rints = 0;
		while (!q[10] && rints < 30) begin rd16(A_RDP, q); rints++; end
		chk(q[10], $sformatf("no RINT within 30 CSR0 reads after TINT (CSR0 %h)", q));
		$display("  case %0d: RINT after %0d CSR0 reads past TINT, max reg_wait %0d", cs, rints, max_wait);
		// 6: compare the buffers (frame + FCS: always 32 bytes land in the RX buffer)
		chk_buf(24'h8048, 0, ncmp, 1, "RX buffer vs TX frame (ROM compare)");
		if (ncmp < 32) chk_buf(24'h8048 + ncmp, ncmp, 32 - ncmp, 1, "RX buffer FCS bytes");
		chk_host8(24'h8068, 8'hEE, "byte after the 32-byte RX buffer");
		if (cs == 1) begin
			reg [15:0] a, b;
			mr16(24'h8064, a); mr16(24'h8066, b);
			chk({a, b} == 32'h447B9FB0, $sformatf("case 1: FCS bytes in RX buffer %h, want 447B9FB0", {a, b}));
		end
		// 7: errors
		mr16(24'h801A, rmd1); mr16(24'h801E, rmd3); mr16(24'h8022, tmd1); mr16(24'h8026, tmd3);
		chk(!q[15], $sformatf("CSR0.ERR set (%h)", q));
		chk(!tmd1[14], $sformatf("TMD1.ERR set (%h)", tmd1));
		chk(tmd1[15:8] == 8'h03, $sformatf("TMD1 %h, want OWN clear, STP|ENP", tmd1));
		chk(tmd3 == 16'h0000, $sformatf("TMD3 %h, want 0", tmd3));
		if (badfcs) begin
			chk(rmd1[15:8] == 8'h4B, $sformatf("bad software FCS: RMD1 %h, want ERR|CRC|STP|ENP, OWN clear", rmd1));
		end else begin
			chk(!rmd1[14], $sformatf("RMD1.ERR set (%h)", rmd1));
			chk(rmd1[15:8] == 8'h03, $sformatf("RMD1 %h, want OWN clear, STP|ENP", rmd1));
			chk(rmd3[11:0] == 12'd32, $sformatf("RMD3 MCNT %0d, want 32", rmd3[11:0]));
		end
	end
	repeat (POLL + 100) @(posedge clk); #1;
	chk(tx_count == lb_tx_start, "a loopback frame reached tx_send");
	rd16(A_RDP, q);
	chk((q & (CERR | MERR | BABL)) == 0, $sformatf("CSR0 %h has CERR/MERR/BABL", q));
	if (ext) begin
		rd8(A_STAT, st);
		chk(!q[13], "external loopback: CERR (NO HEARTBEAT)");
	end
endtask

task automatic test_loopback();
	reg [7:0] st;
	cpu_gap = 8;
	for (int cs = 1; cs <= 8; cs++) rom_lb_case(cs);
	test = "c loopback end";
	rom_handshake();
	wr16(A_ID, 16'h0001);
endtask

// =======================================================================
// d. NetBSD
// =======================================================================
localparam [23:0] NB_RMD = 24'h0020, NB_TMD = 24'h0060, NB_RBUF = 24'h0070, NB_TBUF = 24'h3070;
integer nb_rpos = 0, nb_tpos = 0;
reg [63:0] nb_ladrf;

// hp300 leintr + am7990_intr up to (but not including) re-enabling INEA
task automatic nb_intr_impl(output [15:0] isr);
	reg [7:0] st; reg [15:0] q;
	rd8(A_STAT, st);
	chk(st[6], $sformatf("leintr: status %h has no LE_IR", st));
	nb_rdcsr(0, isr);
	chk(isr[7], $sformatf("am7990_intr: CSR0 %h has no INTR", isr));
	nb_wrcsr(0, isr & ~(INEA | TDMD | STOP | STRT | INIT));
	chk((isr & (RXON | TXON)) == (RXON | TXON), $sformatf("CSR0 %h: RXON or TXON off (NetBSD resets)", isr));
	chk(!(isr & ERR), $sformatf("CSR0 %h: ERR", isr));
	nb_rdcsr(0, q);
	chk((q & (BABL | MISS | MERR | RINT | TINT | IDON | INTR | INEA)) == 0,
		$sformatf("CSR0 %h after the W1C write-back of %h, want flags, INTR and INEA clear", q, isr));
	chk((q & (RXON | TXON | STRT)) == (RXON | TXON | STRT), $sformatf("CSR0 %h: writing read-only bits changed RXON/TXON/STRT", q));
	rd8(A_STAT, st);
	chk(!st[6], $sformatf("status %h: IP still set", st));
	chk(!irq, "irq still asserted after the write-back");
endtask

task automatic nb_send_impl(input integer len, input integer seed, input [47:0] dst);
	integer c0, n; reg [15:0] isr; reg [31:0] a, b; reg [23:0] tb;
	n = len < 60 ? 60 : len;
	mkframe(dst, MAC, len, seed);
	for (int i = len; i < 60; i++) fb[i] = 8'h00;           // NetBSD pads to 60
	tb = NB_TBUF + 24'(nb_tpos * 1536);
	put_bytes(tb, 0, n, 1, 1);                               // bus_space_write_region_1
	c0 = tx_count;
	wr32(hb(NB_TMD + 24'(8 * nb_tpos) + 4), {16'hF000 | (16'(-n) & 16'h0FFF), 16'h0000});
	wr32(hb(NB_TMD + 24'(8 * nb_tpos)), {tb[15:0], 8'h83, tb[23:16]});
	nb_wrcsr(0, INEA | TDMD);
	wait_tx(c0 + 1, 40000);
	chk(tx_count == c0 + 1, $sformatf("frame of %0d bytes not sent (tx_count %0d)", n, tx_count - c0));
	if (tx_count > c0) chk_tx(c0, n, $sformatf("transmit %0d", n));
	wait_csr0(TINT, 100, isr);
	chk(isr[9], $sformatf("no TINT after a transmit (CSR0 %h)", isr));
	repeat (2) @(posedge clk); #1;
	chk(irq, "irq not asserted on TINT with IE and INEA");
	nb_intr(isr);
	chk(isr[9], "TINT gone before the handler");
	rd32(hb(NB_TMD + 24'(8 * nb_tpos)), a); rd32(hb(NB_TMD + 24'(8 * nb_tpos) + 4), b);
	chk(a[15:8] == 8'h03, $sformatf("TMD1 %h after transmit, want OWN clear, STP|ENP, no ERR", a[15:0]));
	chk(b[15:0] == 16'h0000, $sformatf("TMD3 %h after transmit", b[15:0]));
	nb_wrcsr(0, INEA);
	nb_tpos = (nb_tpos + 1) % 2;
endtask

// receive one wire frame of n bytes (FCS included); expect = accepted
task automatic nb_recv_impl(input [47:0] dst, input integer n, input integer seed, input bit accept, input string what);
	reg [15:0] q, isr; reg [7:0] st; reg [31:0] a, b; reg [23:0] rb;
	test = $sformatf("d NetBSD receive %s", what);
	mkframe(dst, 48'h00_11_22_33_44_55, n - 4, seed); add_fcs();
	offer();
	rb = NB_RBUF + 24'(nb_rpos * 1536);
	if (accept) begin
		wait_csr0(RINT, 100, q);
		chk(q[10], $sformatf("no RINT (CSR0 %h)", q));
		repeat (2) @(posedge clk); #1;
		chk(irq, "irq not asserted on RINT with IE and INEA");
		nb_intr(isr);
		chk(isr[10], "RINT gone before the handler");
		rd32(hb(NB_RMD + 24'(8 * nb_rpos)), a); rd32(hb(NB_RMD + 24'(8 * nb_rpos) + 4), b);
		chk(a[15:8] == 8'h03, $sformatf("RMD1 %h, want OWN clear, STP|ENP, no error", a[15:0]));
		chk(b[11:0] == 12'(n), $sformatf("MCNT %0d, want %0d (length with FCS)", b[11:0], n));
		chk_buf(rb, 0, n, 1, "RX buffer");
		// am7990_rint: give the descriptor back
		wr32(hb(NB_RMD + 24'(8 * nb_rpos) + 4), {16'hF000 | (16'(-1536) & 16'h0FFF), 16'h0000});
		wr32(hb(NB_RMD + 24'(8 * nb_rpos)), {rb[15:0], 8'h80, rb[23:16]});
		nb_wrcsr(0, INEA);
		nb_rpos = (nb_rpos + 1) % 8;
	end else begin
		repeat (300) @(posedge clk); #1;
		nb_rdcsr(0, q);
		chk((q & (RINT | MISS | ERR)) == 0, $sformatf("dropped frame: CSR0 %h has RINT/MISS/ERR", q));
		chk(!irq, "dropped frame: irq asserted");
		rd32(hb(NB_RMD + 24'(8 * nb_rpos)), a); rd32(hb(NB_RMD + 24'(8 * nb_rpos) + 4), b);
		chk(a[15:0] == {8'h80, rb[23:16]} && b[15:0] == 16'h0000, $sformatf("dropped frame: RMD changed (%h %h)", a, b));
	end
endtask

task automatic test_netbsd();
	reg [47:0] mac, miss_mc; reg [7:0] h, l, st; reg [15:0] q, isr; integer t, pc, c0;
	reg [5:0] h1, h2;
	test = "d NetBSD attach"; cpu_gap = 2;
	wr8(16'h0001, 8'hFF);
	rd8(A_STAT, st); chk(!st[2], "ACK set right after ID <- $FF");
	for (int i = 0; i < 6; i++) begin
		rd8(16'hC000 + 16'(4 * (2 + i) + 1), h); rd8(16'hC000 + 16'(4 * (2 + i) + 3), l);
		mac[47 - 8 * i -: 8] = {h[3:0], l[3:0]};
	end
	chk(mac == MAC, $sformatf("MAC from NOVRAM %h, want %h", mac, MAC));
	wr8(A_STAT, 8'h80);                                      // LE_IE
	h1 = mhash(48'h01_00_5E_00_00_01); h2 = mhash(48'h09_00_09_00_00_01);
	nb_ladrf = 64'h0; nb_ladrf[h1] = 1; nb_ladrf[h2] = 1;
	miss_mc = 48'h01_00_5E_00_00_02;
	while (nb_ladrf[mhash(miss_mc)]) miss_mc++;
	// lance_init
	test = "d NetBSD init";
	nb_wrcsr(0, STOP);
	nb_wrcsr(3, 16'h0004);
	// am7990_meminit (copytodesc = memcpy: longwords)
	wr32(hb(0),  {16'h0000, mac[39:32], mac[47:40]});
	wr32(hb(4),  {mac[23:16], mac[31:24], mac[7:0], mac[15:8]});
	wr32(hb(8),  {nb_ladrf[15:0], nb_ladrf[31:16]});
	wr32(hb(12), {nb_ladrf[47:32], nb_ladrf[63:48]});
	wr32(hb(16), {NB_RMD[15:0], 8'h60, NB_RMD[23:16]});     // RLEN 3: 8
	wr32(hb(20), {NB_TMD[15:0], 8'h20, NB_TMD[23:16]});     // TLEN 1: 2
	for (int i = 0; i < 8; i++) begin
		reg [23:0] rb; rb = NB_RBUF + 24'(i * 1536);
		wr32(hb(NB_RMD + 24'(8 * i)), {rb[15:0], 8'h80, rb[23:16]});
		wr32(hb(NB_RMD + 24'(8 * i) + 4), {16'hF000 | (16'(-1536) & 16'h0FFF), 16'h0000});
	end
	for (int i = 0; i < 2; i++) begin
		reg [23:0] tb; tb = NB_TBUF + 24'(i * 1536);
		wr32(hb(NB_TMD + 24'(8 * i)), {tb[15:0], 8'h00, tb[23:16]});
		wr32(hb(NB_TMD + 24'(8 * i) + 4), {16'hF000, 16'h0000});
	end
	nb_wrcsr(1, 0); nb_wrcsr(2, 0);
	pc = padr_cnt;
	nb_wrcsr(0, INIT);
	t = 0; do begin nb_rdcsr(0, q); t++; end while (!q[8] && t < 100);
	chk(q[8], $sformatf("no IDON after INIT (CSR0 %h)", q));
	chk(padr_cnt > pc && last_padr == MAC, $sformatf("padr_stb/padr after INIT: %0d strobes, %h", padr_cnt - pc, last_padr));
	nb_wrcsr(0, INEA | STRT);
	nb_rdcsr(0, q);
	chk((q & (RXON | TXON | INEA | STRT | IDON | INTR | STOP)) == (RXON | TXON | INEA | STRT | IDON | INTR),
		$sformatf("CSR0 %h after INEA|STRT, want RXON TXON INEA STRT IDON INTR, no STOP", q));
	repeat (2) @(posedge clk); #1;
	chk(irq, "irq not asserted with IDON pending, INEA and IE");
	nb_intr(isr);
	chk(isr[8], "IDON not seen by the handler");
	nb_wrcsr(0, INEA);
	nb_rdcsr(0, q);
	chk((q & ~(INIT | TDMD)) == (INEA | RXON | TXON | STRT), $sformatf("CSR0 %h after the handler, want 0072", q));

	// ---- transmit ----
	test = "d NetBSD transmit";
	nb_send(42, 1, 48'hFF_FF_FF_FF_FF_FF);       // ARP request, padded to 60
	nb_send(61, 2, 48'h08_00_09_11_22_33);
	nb_send(99, 3, 48'h08_00_09_11_22_33);
	nb_send(1514, 4, 48'h08_00_09_11_22_33);
	nb_send(333, 5, 48'h08_00_09_11_22_33);
	nb_send(60, 6, 48'h08_00_09_11_22_33);
	// tx_ready held low: nothing may be written until the wire is free
	test = "d NetBSD transmit, wire busy";
	tx_hold = 1;
	repeat (3) @(posedge clk); #1;
	fork
		begin repeat (3000) @(posedge clk); #1; tx_hold = 0; end
		nb_send(77, 7, 48'h08_00_09_11_22_33);
	join
	// two descriptors, one TDMD
	test = "d NetBSD transmit, two queued";
	c0 = tx_count;
	for (int k = 0; k < 2; k++) begin
		reg [23:0] tb; tb = NB_TBUF + 24'(((nb_tpos + k) % 2) * 1536);
		mkframe(48'h08_00_09_11_22_33, MAC, 64 + 17 * k, 20 + k);
		put_bytes(tb, 0, 64 + 17 * k, 1, 0);
		wr32(hb(NB_TMD + 24'(8 * ((nb_tpos + k) % 2)) + 4), {16'hF000 | (16'(-(64 + 17 * k)) & 16'h0FFF), 16'h0000});
		wr32(hb(NB_TMD + 24'(8 * ((nb_tpos + k) % 2))), {tb[15:0], 8'h83, tb[23:16]});
	end
	nb_wrcsr(0, INEA | TDMD);
	wait_tx(c0 + 2, 6 * POLL + 20000);
	chk(tx_count == c0 + 2, $sformatf("two queued frames: %0d sent", tx_count - c0));
	mkframe(48'h08_00_09_11_22_33, MAC, 64, 20); if (tx_count > c0) chk_tx(c0, 64, "queued frame 1");
	mkframe(48'h08_00_09_11_22_33, MAC, 81, 21); if (tx_count > c0 + 1) chk_tx(c0 + 1, 81, "queued frame 2");
	wait_csr0(TINT, 100, q);
	nb_intr(isr);
	nb_wrcsr(0, INEA);
	for (int k = 0; k < 2; k++) begin
		reg [31:0] a; rd32(hb(NB_TMD + 24'(8 * k)), a);
		chk(a[15:8] == 8'h03, $sformatf("queued TMD%0d bits %h", k, a[15:8]));
	end

	// ---- receive ----
	nb_recv(MAC, 64, 1, 1, "unicast 64");
	nb_recv(48'hFF_FF_FF_FF_FF_FF, 104, 2, 1, "broadcast");
	nb_recv(48'h01_00_5E_00_00_01, 90, 3, 1, "multicast hit (224.0.0.1)");
	nb_recv(48'h09_00_09_00_00_01, 70, 4, 1, "multicast hit (HP Probe)");
	nb_recv(miss_mc, 90, 5, 0, "multicast miss");
	nb_recv(MAC ^ 48'h1, 90, 6, 0, "wrong unicast");
	nb_recv(48'h0A_00_09_38_A5_C3, 90, 6, 0, "wrong unicast (first byte)");
	nb_recv(MAC, 63, 7, 0, "runt 63");
	nb_recv(MAC, 1518, 8, 1, "unicast 1518");
	nb_recv(MAC, 81, 9, 1, "unicast odd 81");
	nb_recv(MAC, 65, 10, 1, "unicast odd 65");
	nb_recv(MAC, 200, 11, 1, "unicast 200");
	nb_recv(MAC, 300, 12, 1, "unicast 300 (ring wraps)");

	// ---- interrupt pin, IE, INEA and W1C ----
	test = "d NetBSD interrupt/W1C";
	mkframe(MAC, 48'h00_11_22_33_44_55, 100, 13); add_fcs(); offer();
	wait_csr0(RINT, 100, q);
	chk(q[10], "no RINT");
	repeat (2) @(posedge clk); #1;
	chk(irq, "irq not asserted");
	wr8(A_STAT, 8'h00);
	rd8(A_STAT, st); chk(st[6], $sformatf("status %h: IP must be raw (set with IE = 0)", st));
	chk(!irq, "irq asserted with IE = 0");
	wr8(A_STAT, 8'h80);
	repeat (2) @(posedge clk); #1;
	chk(irq, "irq not back with IE = 1");
	nb_wrcsr(0, INEA);                         // no W1C bits
	nb_rdcsr(0, q); chk(q[10], "RINT cleared by writing 0 to it");
	nb_wrcsr(0, INEA | TINT | IDON);           // other W1C bits
	nb_rdcsr(0, q); chk(q[10], "RINT cleared by writing TINT|IDON");
	nb_wrcsr(0, 16'h0000);                     // INEA off
	rd8(A_STAT, st); chk(!st[6], $sformatf("status %h: IP set with INEA = 0", st));
	chk(!irq, "irq with INEA = 0");
	nb_rdcsr(0, q); chk(q[10] && q[7], $sformatf("CSR0 %h: RINT/INTR lost when INEA cleared", q));
	nb_wrcsr(0, INEA);
	rd8(A_STAT, st); chk(st[6], $sformatf("status %h: IP not back with INEA", st));
	nb_wrcsr(0, INEA | RINT);
	nb_rdcsr(0, q); chk(!q[10] && !q[7], $sformatf("CSR0 %h: RINT/INTR not cleared by W1C", q));
	rd8(A_STAT, st); chk(!st[6], "IP still set after W1C");
	chk(!irq, "irq still asserted after W1C");
	begin
		reg [23:0] rb; rb = NB_RBUF + 24'(nb_rpos * 1536);
		chk_buf(rb, 0, 104, 1, "RX buffer");
		wr32(hb(NB_RMD + 24'(8 * nb_rpos) + 4), {16'hF000 | (16'(-1536) & 16'h0FFF), 16'h0000});
		wr32(hb(NB_RMD + 24'(8 * nb_rpos)), {rb[15:0], 8'h80, rb[23:16]});
		nb_rpos = (nb_rpos + 1) % 8;
	end
	nb_wrcsr(0, STOP);
	wr8(16'h0001, 8'hFF);
endtask

// =======================================================================
// e. rings and register corner cases
// =======================================================================
localparam [23:0] RR = 24'h0100, TR = 24'h0500;           // ring bases (up to 128 entries)

task automatic lance_init_impl(input [15:0] mode, input [63:0] ladrf, input [23:0] rdra, input integer rlog,
                          input [23:0] tdra, input integer tlog, input [15:0] csr3);
	reg [15:0] q; integer t;
	csr_w(0, STOP);
	mw16(0, mode);
	mw16(2, {MAC[39:32], MAC[47:40]}); mw16(4, {MAC[23:16], MAC[31:24]}); mw16(6, {MAC[7:0], MAC[15:8]});
	mw16(8, ladrf[15:0]); mw16(10, ladrf[31:16]); mw16(12, ladrf[47:32]); mw16(14, ladrf[63:48]);
	mw16(16, rdra[15:0]); mw16(18, {3'(rlog), 5'd0, rdra[23:16]});
	mw16(20, tdra[15:0]); mw16(22, {3'(tlog), 5'd0, tdra[23:16]});
	csr_w(1, 0); csr_w(2, 0); csr_w(3, csr3);
	csr_w(0, INIT);
	t = 0; do begin rd16(A_RDP, q); t++; end while (!q[8] && t < 100);
	chk(q[8], $sformatf("INIT: no IDON (CSR0 %h)", q));
	wr16(A_RDP, INEA | STRT);
	wr16(A_RDP, INEA | IDON);
	rd16(A_RDP, q);
	chk((q & ~(INIT | TDMD)) == (INEA | RXON | TXON | STRT), $sformatf("CSR0 %h after start, want 0072", q));
endtask
task automatic clear_ring_impl(input [23:0] ring, input integer n);
	for (int i = 0; i < n; i++) begin
		mw16(ring + 24'(8 * i) + 2, 16'h0000); mw16(ring + 24'(8 * i) + 6, 16'h0000);
	end
endtask
task automatic tdmd(); wr16(A_RAP, 0); wr16(A_RDP, INEA | TDMD); endtask
task automatic w1c(input [15:0] bits); wr16(A_RAP, 0); wr16(A_RDP, INEA | bits); endtask

task automatic test_rings();
	reg [15:0] q, save [0:3]; integer c0; reg [31:0] l;
	cpu_gap = 2;
	wr16(A_ID, 16'h0001);

	// ---- e1: TX chaining, odd starts and ends, HADR aliasing ----
	test = "e1 TX chain";
	clear_ring(TR, 8);
	lance_init(16'h0000, 64'h0, RR, 3, TR, 3, 16'h0004);
	fill(24'h1000, 24'h0600, 16'hEEEE);
	mkframe(48'h08_00_09_11_22_33, MAC, 62, 31);
	put_bytes(24'h1001, 0, 20, 1, 0); put_bytes(24'h1101, 20, 33, 1, 0); put_bytes(24'h1200, 53, 9, 1, 0);
	wmd(TR, 2, 24'h1200, 16'h8100, 9, 0);
	wmd(TR, 1, 24'h1101, 16'h8000, 33, 0);
	wmd(TR, 0, 24'h1001, 16'h8200, 20, 0);
	c0 = tx_count; tdmd();
	wait_tx(c0 + 1, 20000);
	chk(tx_count == c0 + 1, "3-buffer chain not sent");
	if (tx_count > c0) chk_tx(c0, 62, "3-buffer chain");
	wait_csr0(TINT, 100, q); chk(q[9], "3-buffer chain: no TINT");
	rmd(TR, 0); chk(md[1][15:8] == 8'h02, $sformatf("chain TMD0 bits %h, want STP only", md[1][15:8]));
	rmd(TR, 1); chk(md[1][15:8] == 8'h00, $sformatf("chain TMD1 bits %h, want 0", md[1][15:8]));
	rmd(TR, 2); chk(md[1][15:8] == 8'h01, $sformatf("chain TMD2 bits %h, want ENP only", md[1][15:8]));
	chk(md[3] == 0, $sformatf("chain TMD3 %h", md[3]));
	w1c(TINT);
	chk_md_fixed(TR, 0, 24'h1001, 20, "3-buffer chain");
	chk_md_fixed(TR, 1, 24'h1101, 33, "3-buffer chain");
	chk_md_fixed(TR, 2, 24'h1200, 9, "3-buffer chain");
	// two buffers; the second addressed as $FFD400 (bits 23:14 ignored: RAM $1400)
	mkframe(48'h08_00_09_11_22_33, MAC, 71, 32);
	put_bytes(24'h1301, 0, 31, 1, 0); put_bytes(24'h1400, 31, 40, 1, 0);
	wmd(TR, 4, 24'hFFD400, 16'h8100, 40, 0);
	wmd(TR, 3, 24'h1301, 16'h8200, 31, 0);
	c0 = tx_count; tdmd();
	wait_tx(c0 + 1, 20000);
	chk(tx_count == c0 + 1, "2-buffer chain not sent");
	if (tx_count > c0) chk_tx(c0, 71, "2-buffer chain (odd start/end, HADR alias)");
	wait_csr0(TINT, 100, q); w1c(TINT);
	rmd(TR, 3); chk(md[1][15:8] == 8'h02, $sformatf("TMD3 bits %h", md[1][15:8]));
	rmd(TR, 4); chk(md[1][15:8] == 8'h01, $sformatf("TMD4 bits %h", md[1][15:8]));
	chk_md_fixed(TR, 3, 24'h1301, 31, "2-buffer chain");
	chk_md_fixed(TR, 4, 24'hFFD400, 40, "2-buffer chain");
	// one buffer, odd start and odd end
	mkframe(48'h08_00_09_11_22_33, MAC, 61, 33);
	put_bytes(24'h1501, 0, 61, 1, 0);
	wmd(TR, 5, 24'h1501, 16'h8300, 61, 0);
	c0 = tx_count; tdmd();
	wait_tx(c0 + 1, 20000);
	if (tx_count > c0) chk_tx(c0, 61, "single odd buffer"); else chk(0, "single odd buffer not sent");
	wait_csr0(TINT, 100, q); w1c(TINT);

	// ---- e2: chain runs into a descriptor the LANCE does not own ----
	test = "e2 TX chain error";
	mkframe(48'h08_00_09_11_22_33, MAC, 40, 34);
	put_bytes(24'h1600, 0, 40, 1, 0);
	wmd(TR, 7, 24'h1700, 16'h0000, 40, 0);
	wmd(TR, 6, 24'h1600, 16'h8200, 40, 0);
	c0 = tx_count; tdmd();
	wait_csr0(TINT, 300, q);
	chk(q[9], $sformatf("no TINT after a chain error (CSR0 %h)", q));
	rmd(TR, 6);
	chk(md[1][15:8] == 8'h42, $sformatf("TMD1 %h, want OWN clear, ERR|STP", md[1]));
	chk((md[3] & 16'hC000) == 16'hC000, $sformatf("TMD3 %h, want BUFF|UFLO", md[3]));
	rmd(TR, 7);
	chk(md[1] == 16'h0000, $sformatf("non-OWN TMD7 written: %h", md[1]));
	chk_md_fixed(TR, 6, 24'h1600, 40, "TX chain error");
	chk_md_fixed(TR, 7, 24'h1700, 40, "TX chain error");
	rd16(A_RDP, q);
	chk(!q[4], $sformatf("CSR0 %h: TXON still on after a chain error", q));
	chk(q[5], $sformatf("CSR0 %h: RXON went off after a TX chain error", q));
	$display("  e2: %0d frame(s) reached the wire for the broken chain (not checked)", tx_count - c0);

	// ---- e3: OWN without STP is skipped ----
	test = "e3 TX OWN without STP";
	clear_ring(TR, 8);
	lance_init(16'h0000, 64'h0, RR, 3, TR, 3, 16'h0004);
	mkframe(48'h08_00_09_99_99_99, MAC, 50, 35); put_bytes(24'h1700, 0, 50, 1, 0);
	mkframe(48'h08_00_09_11_22_33, MAC, 60, 36); put_bytes(24'h1800, 0, 60, 1, 0);
	wmd(TR, 1, 24'h1800, 16'h8300, 60, 0);
	wmd(TR, 0, 24'h1700, 16'h8000, 50, 0);
	c0 = tx_count; tdmd();
	wait_tx(c0 + 1, 6 * POLL + 5000);
	chk(tx_count >= c0 + 1, "frame after a skipped descriptor never sent");
	if (tx_count > c0) chk_tx(c0, 60, "frame after the skipped descriptor");
	repeat (2 * POLL) @(posedge clk); #1;
	chk(tx_count == c0 + 1, $sformatf("%0d frames sent, want 1", tx_count - c0));
	rmd(TR, 0); chk(md[1] == 16'h0000, $sformatf("skipped TMD0 word 1 %h, want 0000 (OWN cleared only)", md[1]));
	rmd(TR, 1); chk(md[1][15:8] == 8'h03, $sformatf("TMD1 bits %h", md[1][15:8]));
	wait_csr0(TINT, 100, q); w1c(TINT);

	// ---- e4: RX chained across 3 buffers ----
	test = "e4 RX chain";
	clear_ring(RR, 4);
	fill(24'h2000, 24'h0400, 16'hEEEE);
	wmd(RR, 0, 24'h2001, 16'h8000, 64, 0);
	wmd(RR, 1, 24'h2100, 16'h8000, 64, 0);
	wmd(RR, 2, 24'h2201, 16'h8000, 64, 0);
	wmd(RR, 3, 24'h2300, 16'h0000, 64, 0);
	lance_init(16'h0000, 64'h0, RR, 2, TR, 3, 16'h0004);
	mkframe(MAC, 48'h00_11_22_33_44_55, 146, 41); add_fcs();
	offer();
	wait_csr0(RINT, 100, q); chk(q[10], "no RINT");
	rmd(RR, 0); chk(md[1][15:8] == 8'h02, $sformatf("RMD0 bits %h, want STP", md[1][15:8]));
	rmd(RR, 1); chk(md[1][15:8] == 8'h00, $sformatf("RMD1 bits %h, want none", md[1][15:8]));
	rmd(RR, 2); chk(md[1][15:8] == 8'h01, $sformatf("RMD2 bits %h, want ENP", md[1][15:8]));
	chk(md[3][11:0] == 12'd150, $sformatf("RMD2 MCNT %0d, want 150", md[3][11:0]));
	rmd(RR, 3); chk(md[1] == 16'h0000 && md[3] == 16'h0000, $sformatf("RMD3 touched: %h %h", md[1], md[3]));
	chk_buf(24'h2001, 0, 64, 1, "chain buffer 0");
	chk_buf(24'h2100, 64, 64, 1, "chain buffer 1");
	chk_buf(24'h2201, 128, 22, 1, "chain buffer 2");
	chk_host8(24'h2000, 8'hEE, "before buffer 0");
	chk_host8(24'h2041, 8'hEE, "after buffer 0");
	chk_host8(24'h2140, 8'hEE, "after buffer 1");
	chk_host8(24'h2200, 8'hEE, "before buffer 2");
	chk_host8(24'h2217, 8'hEE, "after the frame in buffer 2");
	chk_md_fixed(RR, 0, 24'h2001, 64, "RX chain");
	chk_md_fixed(RR, 1, 24'h2100, 64, "RX chain");
	chk_md_fixed(RR, 2, 24'h2201, 64, "RX chain");
	chk_md_fixed(RR, 3, 24'h2300, 64, "RX chain");
	w1c(RINT);

	// ---- e5: no OWN descriptor: MISS ----
	test = "e5 RX MISS";
	for (int j = 0; j < 4; j++) mr16(RR + 24 + 2 * j, save[j]);
	mkframe(MAC, 48'h00_11_22_33_44_55, 60, 42); add_fcs();
	offer();
	repeat (200) @(posedge clk); #1;
	rd16(A_RDP, q);
	chk((q & (MISS | ERR | INTR)) == (MISS | ERR | INTR), $sformatf("CSR0 %h, want MISS|ERR|INTR", q));
	rmd(RR, 3);
	for (int j = 0; j < 4; j++) chk(md[j] == save[j], $sformatf("MISS wrote RMD3 word %0d: %h", j, md[j]));
	w1c(MISS | RINT);
	rd16(A_RDP, q);
	chk((q & (MISS | ERR | INTR)) == 0, $sformatf("CSR0 %h after W1C of MISS", q));

	// ---- e6: chained receive, next descriptor not OWN: BUFF ----
	test = "e6 RX overflow";
	rmd(RR, 0); save[1] = md[1]; save[3] = md[3];
	wmd(RR, 3, 24'h2300, 16'h8000, 64, 0);
	mkframe(MAC, 48'h00_11_22_33_44_55, 100, 43); add_fcs();
	offer();
	wait_csr0(RINT, 100, q); chk(q[10], $sformatf("no RINT on overflow (CSR0 %h)", q));
	rmd(RR, 3);
	chk(!md[1][15], $sformatf("RMD1 %h: OWN still set", md[1]));
	chk((md[1] & 16'h4600) == 16'h4600, $sformatf("RMD1 %h, want ERR|BUFF|STP", md[1]));
	chk_buf(24'h2300, 0, 64, 1, "overflow buffer");
	rmd(RR, 0);
	chk(md[1] == save[1] && md[3] == save[3], $sformatf("non-OWN RMD0 written on overflow: %h %h", md[1], md[3]));
	chk_md_fixed(RR, 3, 24'h2300, 64, "RX overflow");
	chk_md_fixed(RR, 0, 24'h2001, 64, "RX overflow");
	w1c(RINT);

	// ---- e7: ring wrap at 1, 2, 8, 128 ----
	for (int lg = 0; lg <= 7; lg++) if (lg == 0 || lg == 1 || lg == 3 || lg == 7) begin
		integer n, i, bad;
		n = 1 << lg;
		test = $sformatf("e7 ring wrap %0d", n);
		clear_ring(TR, n);
		for (i = 0; i < n; i++) wmd(RR, i, 24'h0900 + 24'(80 * i), 16'h8000, 80, 0);
		lance_init(16'h0000, 64'h0, RR, lg, TR, lg, 16'h0004);
		bad = errors;
		for (int f = 0; f < n + 3 && errors - bad < 4; f++) begin
			i = f % n;
			mkframe(MAC, 48'h00_11_22_33_44_55, 60, f * 7 + n); fb[14] = 8'(f); fb[15] = 8'(n); add_fcs();
			offer();
			wait_csr0(RINT, 100, q);
			chk(q[10], $sformatf("frame %0d: no RINT", f));
			rmd(RR, i);
			chk(md[1][15:8] == 8'h03 && md[3][11:0] == 12'd64,
				$sformatf("frame %0d: RMD%0d %h MCNT %0d, want STP|ENP, 64", f, i, md[1], md[3][11:0]));
			chk_buf(24'h0900 + 24'(80 * i), 0, 64, 1, $sformatf("frame %0d in RMD%0d", f, i));
			mw16(RR + 24'(8 * i) + 6, 16'h0000); mw16(RR + 24'(8 * i) + 2, 16'h8000);
			w1c(RINT);
		end
		bad = errors;
		for (int f = 0; f < n + 3 && errors - bad < 4; f++) begin
			reg [23:0] tb;
			i = f % n; tb = 24'h3100 + 24'(64 * (f % 8));
			mkframe(48'h08_00_09_11_22_33, MAC, 60, f * 5 + n + 100); fb[14] = 8'(f);
			put_bytes(tb, 0, 60, 1, 0);
			wmd(TR, i, tb, 16'h8300, 60, 0);
			c0 = tx_count; tdmd();
			wait_tx(c0 + 1, 20000);
			chk(tx_count == c0 + 1, $sformatf("TX frame %0d (TMD%0d) not sent", f, i));
			if (tx_count > c0) chk_tx(c0, 60, $sformatf("TX frame %0d", f));
			wait_csr0(TINT, 100, q);
			rmd(TR, i); chk(md[1][15:8] == 8'h03, $sformatf("TX frame %0d: TMD%0d bits %h", f, i, md[1][15:8]));
			w1c(TINT);
		end
	end

	// ---- e8: BSWP = 0 ----
	test = "e8 BSWP=0";
	clear_ring(TR, 2);
	wmd(RR, 0, 24'h3101, 16'h8000, 128, 0);
	wmd(RR, 1, 24'h3201, 16'h8000, 128, 0);
	fill(24'h3100, 24'h0100, 16'hEEEE);
	lance_init(16'h0000, 64'h0, RR, 1, TR, 1, 16'h0000);
	mkframe(48'h08_00_09_11_22_33, MAC, 61, 51);
	put_bytes(24'h3001, 0, 61, 0, 0);
	wmd(TR, 0, 24'h3001, 16'h8300, 61, 0);
	c0 = tx_count; tdmd();
	wait_tx(c0 + 1, 20000);
	if (tx_count > c0) chk_tx(c0, 61, "BSWP=0 transmit"); else chk(0, "BSWP=0 frame not sent");
	wait_csr0(TINT, 100, q); w1c(TINT);
	mkframe(MAC, 48'h00_11_22_33_44_55, 66, 52); add_fcs();
	offer();
	wait_csr0(RINT, 100, q); chk(q[10], "BSWP=0: no RINT");
	chk_buf(24'h3101, 0, 70, 0, "BSWP=0 receive");
	chk_host8(24'h3101, 8'hEE, "BSWP=0: byte before the buffer (host +$3101)");
	chk_host8(24'h3146, 8'hEE, "BSWP=0: byte after the frame (host +$3146)");
	rmd(RR, 0); chk(md[1][15:8] == 8'h03 && md[3][11:0] == 12'd70, $sformatf("BSWP=0 RMD %h MCNT %0d", md[1], md[3][11:0]));
	w1c(RINT);

	// ---- e9: STOP overrides INIT/STRT in one write ----
	test = "e9 STOP priority";
	wr16(A_RAP, 0);
	wr16(A_RDP, STOP | STRT | INIT);
	rd16(A_RDP, q); chk(q == STOP, $sformatf("CSR0 %h after STOP|STRT|INIT while running, want 0004", q));
	repeat (3 * IDON_DLY + 100) @(posedge clk); #1;
	rd16(A_RDP, q); chk(q == STOP, $sformatf("CSR0 %h later, want 0004 (no IDON)", q));
	wr16(A_RDP, INEA | TDMD | STOP | STRT | INIT);
	repeat (3 * IDON_DLY + 100) @(posedge clk); #1;
	rd16(A_RDP, q); chk(q == STOP, $sformatf("CSR0 %h after INEA|TDMD|STOP|STRT|INIT while stopped, want 0004", q));
	wr16(A_RDP, INEA);
	rd16(A_RDP, q); chk(q == STOP, $sformatf("CSR0 %h: INEA accepted while stopped", q));
	// RXON off: a wire frame is dropped
	test = "e9 receiver off";
	mkframe(MAC, 48'h00_11_22_33_44_55, 60, 53); add_fcs();
	offer();
	repeat (100) @(posedge clk); #1;
	rd16(A_RDP, q); chk(q == STOP, $sformatf("CSR0 %h after a frame with the receiver off", q));

	// ---- e10: read-only CSR0 bits; CSR1-3 locked while running ----
	test = "e10 CSR0 read-only bits";
	clear_ring(TR, 2);
	lance_init(16'h0000, 64'h0, RR, 1, TR, 1, 16'h0004);
	wr16(A_RDP, ERR | INTR | INEA | RXON | TXON);
	rd16(A_RDP, q); chk((q & ~(INIT | TDMD)) == 16'h0072, $sformatf("CSR0 %h after writing read-only bits, want 0072", q));
	wr16(A_RDP, 16'h0000);
	rd16(A_RDP, q); chk((q & ~(INIT | TDMD)) == 16'h0032, $sformatf("CSR0 %h after writing 0, want 0032", q));
	test = "e10 CSR1-3 while running";
	csr_w(1, 16'h1234); csr_w(2, 16'h0056); csr_w(3, 16'h0000);
	mkframe(48'h08_00_09_11_22_33, MAC, 61, 54);
	put_bytes(24'h3301, 0, 61, 1, 0);                        // BSWP = 1 order
	wmd(TR, 0, 24'h3301, 16'h8300, 61, 0);
	c0 = tx_count; tdmd();
	wait_tx(c0 + 1, 20000);
	if (tx_count > c0) chk_tx(c0, 61, "after CSR3 <- 0 while running (BSWP must stay 1)"); else chk(0, "frame not sent");
	wait_csr0(TINT, 100, q); w1c(TINT);
	csr_w(0, STOP);
	csr_r(1, q); chk(q == 16'h0000, $sformatf("CSR1 %h: written while running", q));
	csr_r(2, q); chk(q[7:0] == 8'h00, $sformatf("CSR2 %h: written while running", q));
	csr_r(3, q); chk(q == 16'h0000, $sformatf("CSR3 %h after STOP, want 0", q));
	csr_w(1, 16'hFFFF); csr_r(1, q); chk(q == 16'hFFFE, $sformatf("CSR1 %h after writing FFFF, want FFFE (bit 0 reads 0)", q));

	// ---- e11: RAP selects ----
	test = "e11 RAP";
	csr_w(1, 16'h1110); csr_w(2, 16'h0022); csr_w(3, 16'h0005);
	wr16(A_RAP, 16'hFFFD); rd16(A_RAP, q); chk(q[1:0] == 2'd1, $sformatf("RAP %h after writing FFFD", q));
	rd16(A_RDP, q); chk(q == 16'h1110, $sformatf("RAP 1: RDP %h, want 1110", q));
	wr16(A_RAP, 2); rd16(A_RDP, q); chk(q[7:0] == 8'h22, $sformatf("RAP 2: RDP %h, want xx22", q));
	wr16(A_RAP, 3); rd16(A_RDP, q); chk(q[2:0] == 3'd5, $sformatf("RAP 3: RDP %h, want 5", q));
	wr16(A_RAP, 0); rd16(A_RDP, q); chk(q == 16'h0004, $sformatf("RAP 0: RDP %h, want 0004", q));
	csr_w(1, 0); csr_w(2, 0);

	// ---- e12: DTCR on the wire: the guest's FCS is not sent ----
	test = "e12 DTCR transmit";
	clear_ring(TR, 2);
	lance_init(16'h0008, 64'h0, RR, 1, TR, 1, 16'h0004);
	mkframe(48'h08_00_09_11_22_33, MAC, 60, 55); add_fcs();
	put_bytes(24'h3401, 0, 64, 1, 0);
	wmd(TR, 0, 24'h3401, 16'h8300, 64, 0);
	c0 = tx_count; tdmd();
	wait_tx(c0 + 1, 20000);
	if (tx_count > c0) chk_tx(c0, 60, "DTCR frame (FCS stripped)"); else chk(0, "DTCR frame not sent");
	wait_csr0(TINT, 100, q); w1c(TINT);
	csr_w(0, STOP);
	wr16(A_ID, 16'h0001);
	repeat (4) @(posedge clk); #1;
	chk(!irq, "irq after the final reset");
endtask


// ------------------------------------------------- operation servers ----
// Every task call is inlined by Verilator.  To keep the generated C++ small, the
// reused multi-access tasks (the *_impl bodies above) run in one server
// process per nesting level; the tasks the tests call only post the
// arguments and wait.  Level 2 uses only bus accesses, level 3 uses level 2,
// level 4 uses level 3.
localparam integer OP_CSR_W = 0;
localparam integer OP_CSR_R = 1;
localparam integer OP_NB_WRCSR = 2;
localparam integer OP_NB_RDCSR = 3;
localparam integer OP_WAIT_CSR0 = 4;
localparam integer OP_FILL = 5;
localparam integer OP_PUT_BYTES = 6;
localparam integer OP_CHK_BUF = 7;
localparam integer OP_CHK_HOST8 = 8;
localparam integer OP_WMD = 9;
localparam integer OP_RMD = 10;
localparam integer OP_CLEAR_RING = 11;
localparam integer OP_LANCE_INIT = 12;
localparam integer OP_CHK_MD_FIXED = 13;
localparam integer OP_NB_INTR = 14;
localparam integer OP_NB_SEND = 15;
localparam integer OP_NB_RECV = 16;

bit         L2_req = 0;
integer     L2_op = 0;
reg  [63:0] L2_a [0:7];
string      L2_s = "";
reg  [15:0] L2_q = 0;
initial forever begin
	wait (L2_req);
	case (L2_op)
	OP_CSR_W: csr_w_impl(L2_a[0], L2_a[1]);
	OP_CSR_R: csr_r_impl(L2_a[0], L2_q);
	OP_NB_WRCSR: nb_wrcsr_impl(L2_a[0], L2_a[1]);
	OP_NB_RDCSR: nb_rdcsr_impl(L2_a[0], L2_q);
	OP_WAIT_CSR0: wait_csr0_impl(L2_a[0], L2_a[1], L2_q);
	OP_FILL: fill_impl(L2_a[0], L2_a[1], L2_a[2]);
	OP_PUT_BYTES: put_bytes_impl(L2_a[0], L2_a[1], L2_a[2], L2_a[3], L2_a[4]);
	OP_CHK_BUF: chk_buf_impl(L2_a[0], L2_a[1], L2_a[2], L2_a[3], L2_s);
	OP_CHK_HOST8: chk_host8_impl(L2_a[0], L2_a[1], L2_s);
	OP_WMD: wmd_impl(L2_a[0], L2_a[1], L2_a[2], L2_a[3], L2_a[4], L2_a[5]);
	OP_RMD: rmd_impl(L2_a[0], L2_a[1]);
	OP_CLEAR_RING: clear_ring_impl(L2_a[0], L2_a[1]);
	default: ;
	endcase
	L2_req = 0;
end
task automatic csr_w(input [1:0] n, input [15:0] d);
	L2_a[0] = 64'(n); L2_a[1] = 64'(d); L2_s = ""; L2_op = OP_CSR_W; L2_req = 1; wait (!L2_req);
endtask
task automatic csr_r(input [1:0] n, output [15:0] q);
	L2_a[0] = 64'(n); L2_s = ""; L2_op = OP_CSR_R; L2_req = 1; wait (!L2_req); q = L2_q;
endtask
task automatic nb_wrcsr(input [15:0] port, input [15:0] d);
	L2_a[0] = 64'(port); L2_a[1] = 64'(d); L2_s = ""; L2_op = OP_NB_WRCSR; L2_req = 1; wait (!L2_req);
endtask
task automatic nb_rdcsr(input [15:0] port, output [15:0] q);
	L2_a[0] = 64'(port); L2_s = ""; L2_op = OP_NB_RDCSR; L2_req = 1; wait (!L2_req); q = L2_q;
endtask
task automatic wait_csr0(input [15:0] mask, input integer maxr, output [15:0] q);
	L2_a[0] = 64'(mask); L2_a[1] = 64'(maxr); L2_s = ""; L2_op = OP_WAIT_CSR0; L2_req = 1; wait (!L2_req); q = L2_q;
endtask
task automatic fill(input [23:0] la, input integer nbytes, input [15:0] w);
	L2_a[0] = 64'(la); L2_a[1] = 64'(nbytes); L2_a[2] = 64'(w); L2_s = ""; L2_op = OP_FILL; L2_req = 1; wait (!L2_req);
endtask
task automatic put_bytes(input [23:0] a, input integer from, input integer n, input bit bswp, input bit bytes_only);
	L2_a[0] = 64'(a); L2_a[1] = 64'(from); L2_a[2] = 64'(n); L2_a[3] = 64'(bswp); L2_a[4] = 64'(bytes_only); L2_s = ""; L2_op = OP_PUT_BYTES; L2_req = 1; wait (!L2_req);
endtask
task automatic chk_buf(input [23:0] a, input integer from, input integer n, input bit bswp, input string what);
	L2_a[0] = 64'(a); L2_a[1] = 64'(from); L2_a[2] = 64'(n); L2_a[3] = 64'(bswp); L2_s = what; L2_op = OP_CHK_BUF; L2_req = 1; wait (!L2_req);
endtask
task automatic chk_host8(input [23:0] la, input [7:0] want, input string what);
	L2_a[0] = 64'(la); L2_a[1] = 64'(want); L2_s = what; L2_op = OP_CHK_HOST8; L2_req = 1; wait (!L2_req);
endtask
task automatic wmd(input [23:0] ring, input integer i, input [23:0] buffer, input [15:0] bits,
                   input integer bcnt, input [15:0] w3);
	L2_a[0] = 64'(ring); L2_a[1] = 64'(i); L2_a[2] = 64'(buffer); L2_a[3] = 64'(bits); L2_a[4] = 64'(bcnt); L2_a[5] = 64'(w3); L2_s = ""; L2_op = OP_WMD; L2_req = 1; wait (!L2_req);
endtask
task automatic rmd(input [23:0] ring, input integer i);
	L2_a[0] = 64'(ring); L2_a[1] = 64'(i); L2_s = ""; L2_op = OP_RMD; L2_req = 1; wait (!L2_req);
endtask
task automatic clear_ring(input [23:0] ring, input integer n);
	L2_a[0] = 64'(ring); L2_a[1] = 64'(n); L2_s = ""; L2_op = OP_CLEAR_RING; L2_req = 1; wait (!L2_req);
endtask

bit         L3_req = 0;
integer     L3_op = 0;
reg  [63:0] L3_a [0:7];
string      L3_s = "";
reg  [15:0] L3_q = 0;
initial forever begin
	wait (L3_req);
	case (L3_op)
	OP_LANCE_INIT: lance_init_impl(L3_a[0], L3_a[1], L3_a[2], L3_a[3], L3_a[4], L3_a[5], L3_a[6]);
	OP_CHK_MD_FIXED: chk_md_fixed_impl(L3_a[0], L3_a[1], L3_a[2], L3_a[3], L3_s);
	OP_NB_INTR: nb_intr_impl(L3_q);
	default: ;
	endcase
	L3_req = 0;
end
task automatic lance_init(input [15:0] mode, input [63:0] ladrf, input [23:0] rdra, input integer rlog,
                          input [23:0] tdra, input integer tlog, input [15:0] csr3);
	L3_a[0] = 64'(mode); L3_a[1] = 64'(ladrf); L3_a[2] = 64'(rdra); L3_a[3] = 64'(rlog); L3_a[4] = 64'(tdra); L3_a[5] = 64'(tlog); L3_a[6] = 64'(csr3); L3_s = ""; L3_op = OP_LANCE_INIT; L3_req = 1; wait (!L3_req);
endtask
task automatic chk_md_fixed(input [23:0] ring, input integer i, input [23:0] buffer, input integer bcnt, input string what);
	L3_a[0] = 64'(ring); L3_a[1] = 64'(i); L3_a[2] = 64'(buffer); L3_a[3] = 64'(bcnt); L3_s = what; L3_op = OP_CHK_MD_FIXED; L3_req = 1; wait (!L3_req);
endtask
task automatic nb_intr(output [15:0] isr);
	 L3_s = ""; L3_op = OP_NB_INTR; L3_req = 1; wait (!L3_req); isr = L3_q;
endtask

bit         L4_req = 0;
integer     L4_op = 0;
reg  [63:0] L4_a [0:7];
string      L4_s = "";
reg  [15:0] L4_q = 0;
initial forever begin
	wait (L4_req);
	case (L4_op)
	OP_NB_SEND: nb_send_impl(L4_a[0], L4_a[1], L4_a[2]);
	OP_NB_RECV: nb_recv_impl(L4_a[0], L4_a[1], L4_a[2], L4_a[3], L4_s);
	default: ;
	endcase
	L4_req = 0;
end
task automatic nb_send(input integer len, input integer seed, input [47:0] dst);
	L4_a[0] = 64'(len); L4_a[1] = 64'(seed); L4_a[2] = 64'(dst); L4_s = ""; L4_op = OP_NB_SEND; L4_req = 1; wait (!L4_req);
endtask
task automatic nb_recv(input [47:0] dst, input integer n, input integer seed, input bit accept, input string what);
	L4_a[0] = 64'(dst); L4_a[1] = 64'(n); L4_a[2] = 64'(seed); L4_a[3] = 64'(accept); L4_s = what; L4_op = OP_NB_RECV; L4_req = 1; wait (!L4_req);
endtask

// =======================================================================
integer sec_err;
task automatic section(input string name);
	if (errors == sec_err) $display("pass  %s", name); else $display("FAIL  %s (%0d)", name, errors - sec_err);
	sec_err = errors;
endtask

initial begin
	sec_err = 0;
	repeat (8) @(posedge clk); #1;
	reset = 0;
	repeat (4) @(posedge clk); #1;
	test_rom_regs();   section("a  ROM register test, status/ACK, RAM test");
	test_novram();     section("b  NOVRAM");
	test_loopback();   section("c  ROM loopback cases 1-6 (+ bad DTCR FCS, external loopback)");
	test_netbsd();     section("d  NetBSD sequence");
	test_rings();      section("e  rings and registers");
	$display("longest reg_wait: %0d clocks; wire frames sent %0d, received %0d", max_wait, tx_count, rx_taken);
	if (errors == 0) $display("ALL TESTS PASSED"); else $display("TEST FAILED (%0d)", errors);
	$finish;
end

initial begin
	#(64'd30 * 64'd20_000_000);
	$display("TEST FAILED (timeout in %s)", test);
	$finish;
end

endmodule
