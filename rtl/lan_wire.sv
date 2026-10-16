//============================================================================
//  lan_wire — the 98643A's wire: the LANCE's frames to and from
//  Main_MiSTer's HP 9000 Ethernet bridge (support/hp9k/hp9k_enet.cpp, a copy
//  of support/sun/sun_enet.cpp), which hands them to eth0, eth1, a macvlan
//  or tap0 on the Linux side.  docs/reference/lan_98643.md §4 and §6.
//
//  The mailbox: 64 KB of DDR3 at ARM physical $1FF0_0000, 64-bit
//  little-endian words; nb_addr is the word (byte offset / 8).  The same
//  layout the 715's i82596.sv and the SS20's eth_hps.vhd use:
//    +$0000 MAGIC    ours, written last at start-up: "H3ETH001" names this
//                    core and its RX ring depth (16) to Main
//    +$0008 GEN      ours, a new value at every start-up
//    +$0010 TX_WPTR  ours: frames posted (free-running; Main reads it)
//    +$0018 TX_RPTR  Main's: frames taken
//    +$0020 RX_WPTR  Main's: frames posted
//    +$0028 RX_RPTR  ours: frames taken
//    +$0030 MAC      ours: bit 63 valid, bits 47:40 the first byte on the wire
//    +$1000 TX ring  8 slots of $800: word 0 bits 10:0 the length, then the
//                    frame, byte i in byte lane i mod 8 of word 1 + i/8.
//                    No FCS (Main sends the bytes as they are).
//    +$5000 RX ring  16 slots of $800: word 0 bits 10:0 the length with
//                    the FCS (Main pads to 60 bytes and appends a good FCS),
//                    bits 21:16 the LADRF hash index of the destination;
//                    then the frame the same way.  Main writes the frame,
//                    then word 0, then RX_WPTR.
//  The pointers are counters; a slot is pointer mod ring size.  Ours are
//  kept as 32 bits, written zero-extended (Main does 64-bit arithmetic).
//
//  Start-up (and again after every reset): MAGIC = 0 (Main stops looking),
//  GEN = the free-running clock count sampled during reset, the four
//  pointers = 0, MAC, then MAGIC.  A mailbox access still in flight when
//  reset arrives is finished first, so the DDR3 port never sees a request
//  withdrawn.  Main notices the new GEN and takes the pointers from the
//  mailbox again.
//
//  TX: the LANCE writes the frame (no FCS) into the 2 KB TX buffer while
//  tx_ready, then pulses tx_send with the length; tx_ready drops at once.
//  When a slot is free (TX_WPTR - TX_RPTR < 8) the frame goes into it word
//  by word, then its length word, then TX_WPTR++, and tx_ready comes back.
//  While the ring is full TX_RPTR is re-read every TXPOLL clocks (RX keeps
//  running meanwhile); full for TXWAIT (50 ms: Main is not running) drops
//  the frame.  With the network Off (ena = 0) frames are taken and dropped
//  at once, so the guest still sees its TINTs.  Lengths of 0 or over 2040
//  (a slot) are dropped too.
//
//  RX: RX_WPTR is polled every POLL clocks (the DDR3 port is shared with
//  the display); while Main is known to be ahead the next slot is fetched
//  at once.  A slot is copied into the 2 KB RX buffer (with its FCS) and
//  offered (rx_avail, rx_len) only after its wire time at 10 Mb/s,
//  (length + 8 preamble + 12 gap) x 8 bit times from when its header was
//  read: hosts hand over bursts (fragments, GRO leftovers) that a guest
//  ring of 8 descriptors cannot absorb at memory speed.  rx_done (the
//  LANCE took or dropped it) frees the buffer and moves RX_RPTR on.  The
//  LANCE must also rx_done a frame it will not take (receiver off, STOP),
//  or RX stalls.  Lengths under 18 or over 1522 (the guests' buffers are
//  1536 bytes) are skipped; with ena = 0 everything Main posted is skipped.
//  The hash in bits 21:16 is not passed on: the LANCE has the CRC for its
//  own filter.  Loopback stays inside the LANCE and never reaches here.
//
//  Main side: rx_ring_slots() in support/hp9k/hp9k_enet.cpp must know the
//  magic (16 slots; the 64 KB window has room for at most 22):
//    #define SB_MAGIC_385  0x4833455448303031ULL   // H3ETH001 (HP9K385)
//    case SB_MAGIC_385: return 16;
//  and the HP9K385 models row in hp9k.cpp needs its network bits "[14:12]".
//
//  Both 2 KB buffers are simple dual-port with a registered read, in plain
//  always blocks so Quartus makes them M10K.
//============================================================================

module lan_wire
#(
	parameter CLK_HZ = 33_000_000,
	parameter BIT_HZ = 10_000_000,            // RX pacing: the wire's bit rate
	parameter POLL   = 20_000,                // clocks between RX_WPTR reads when idle
	parameter TXPOLL = 2_048,                 // clocks between TX_RPTR reads while the ring is full
	parameter TXWAIT = CLK_HZ / 20            // ring full this long: drop the frame (50 ms)
)
(
	input             clk,
	input             reset,
	input             ena,          // OSD network not Off; when 0, TX frames are taken and dropped, nothing is received
	input      [47:0] mac,          // station address, [47:40] = first byte on the wire
	input             mac_stb,      // mac changed (LANCE INIT): rewrite the MAC word
	// TX: the LANCE writes a frame (no FCS) into the wire's 2 KB TX buffer, then pulses tx_send
	output            tx_ready,     // TX buffer free; the LANCE only starts writing when 1
	input             tx_we,
	input      [10:0] tx_addr,
	input       [7:0] tx_wdata,
	input             tx_send,      // one clock; tx_len is the frame length in bytes (no FCS)
	input      [10:0] tx_len,
	// RX: a received frame (with FCS, as Main delivers it) waits in the 2 KB RX buffer
	output            rx_avail,     // a frame is ready (after 10 Mb/s pacing); rx_len valid
	output     [10:0] rx_len,       // bytes including the 4-byte FCS
	input      [10:0] rx_addr,      // byte index; rx_q is that byte one clock later
	output      [7:0] rx_q,
	input             rx_done,      // one clock: the LANCE is finished with the frame (taken or dropped)
	// mailbox port (one 64-bit word at ARM physical 0x1FF00000 + 8*nb_addr), held until nb_ack
	output            nb_req,
	output            nb_we,
	output     [12:0] nb_addr,
	output     [63:0] nb_wdata,
	input             nb_ack,       // one clock; for reads nb_rdata is valid with it
	input      [63:0] nb_rdata
);

localparam [12:0] NB_MAGIC = 13'h0000, NB_GEN = 13'h0001, NB_TXW = 13'h0002, NB_TXR = 13'h0003,
                  NB_RXW   = 13'h0004, NB_RXR = 13'h0005, NB_MAC = 13'h0006;
localparam [12:0] NB_TX = 13'h0200, NB_RX = 13'h0A00;       // $1000 / 8, $5000 / 8; slots of $100 words
localparam [63:0] MAGIC = 64'h4833_4554_4830_3031;          // "H3ETH001"
localparam [31:0] TX_SLOTS = 32'd8, RX_SLOTS = 32'd16;
localparam [10:0] RXMIN = 11'd18, RXMAX = 11'd1522, TXMAX = 11'd2040;

localparam PW  = $clog2(POLL + 1);
localparam TPW = $clog2(TXPOLL + 1);
localparam TWW = $clog2(TXWAIT + 1);

// ---- buffers ---------------------------------------------------------------
reg         tx_free;
reg  [11:0] tp;                               // TX copy: byte position
reg   [7:0] txb [0:2047];
reg   [7:0] txb_q;
always @(posedge clk) begin
	if (tx_we && tx_free) txb[tx_addr] <= tx_wdata;
	txb_q <= txb[tp[10:0]];
end

reg         rxb_we;
reg  [10:0] rxb_wa;
reg   [7:0] rxb_wd;
reg   [7:0] rxb [0:2047];
reg   [7:0] rxb_q;
always @(posedge clk) begin
	if (rxb_we) rxb[rxb_wa] <= rxb_wd;
	rxb_q <= rxb[rx_addr];
end
assign rx_q = rxb_q;

// ---- state -----------------------------------------------------------------
localparam [3:0] S_BOOT = 4'd0, S_IDLE = 4'd1, S_NB = 4'd2, S_TXA = 4'd3, S_TXB = 4'd4,
                 S_TXHDR = 4'd5, S_TXPTR = 4'd6, S_TXDONE = 4'd7, S_TXR = 4'd8,
                 S_RXW = 4'd9, S_RXHDR = 4'd10, S_RXBYTE = 4'd11;
reg   [3:0] st, nret;
reg   [2:0] bk;

reg  [31:0] tick = 32'd0;
reg  [31:0] gen_v;

// mailbox word in flight
reg         n_req, n_we;
reg  [12:0] n_a;
reg  [63:0] n_wd, n_rd;
assign nb_req   = n_req;
assign nb_we    = n_we;
assign nb_addr  = n_a;
assign nb_wdata = n_wd;

// ring pointers: ours, and Main's as last read
reg  [31:0] txw, txr_c, rxr, rxw_c;

// TX
reg         tx_pend;
reg  [10:0] tlen;
reg  [63:0] tw;
reg [TWW-1:0] tx_wait;
reg [TPW-1:0] txr_tmr;
assign tx_ready = tx_free;
wire        tx_room = (txw - txr_c) < TX_SLOTS;
wire [12:0] tslot = NB_TX + {2'd0, txw[2:0], 8'd0};
wire [63:0] tnw = {tp < {1'b0, tlen} ? txb_q : 8'd0, tw[63:8]};

// RX
reg         rx_full, rxr_pend;
reg  [10:0] rlen;
reg   [7:0] rj;                               // word within the slot's frame
reg   [2:0] rk;                               // byte within the word
reg [PW-1:0] poll_tmr;
reg  [14:0] pace;                             // bit times until the frame may be offered
wire [12:0] rslot = NB_RX + {1'b0, rxr[3:0], 8'd0};
assign rx_avail = rx_full && pace == 15'd0;
assign rx_len   = rlen;

// MAC
reg         mac_pend;
wire [63:0] mac_w = {|mac, 15'd0, mac};

// 10 Mb/s bit times
reg  [31:0] acc;
reg         bit_tick;
wire [32:0] acc_n = {1'b0, acc} + BIT_HZ;
wire [32:0] acc_w = acc_n - CLK_HZ;
always @(posedge clk) begin
	if (reset) begin acc <= 32'd0; bit_tick <= 1'b0; end
	else if (acc_n >= CLK_HZ) begin acc <= acc_w[31:0]; bit_tick <= 1'b1; end
	else begin acc <= acc_n[31:0]; bit_tick <= 1'b0; end
end

task nb(input [12:0] a, input w, input [63:0] d, input [3:0] r);
	begin n_a <= a; n_we <= w; n_wd <= d; nret <= r; n_req <= 1'b1; st <= S_NB; end
endtask

always @(posedge clk) begin
	tick <= tick + 32'd1;
	rxb_we <= 1'b0;

	if (reset) begin
		gen_v <= tick;
		st <= S_BOOT; bk <= 3'd0;
		if (nb_ack) n_req <= 1'b0;            // a word in flight finishes; S_BOOT waits for it
		tx_free <= 1'b1; tx_pend <= 1'b0; mac_pend <= 1'b0;
		rx_full <= 1'b0; rxr_pend <= 1'b0; pace <= 15'd0;
		txw <= 32'd0; txr_c <= 32'd0; rxr <= 32'd0; rxw_c <= 32'd0;
		poll_tmr <= {PW{1'b0}}; txr_tmr <= {TPW{1'b0}}; tx_wait <= {TWW{1'b0}};
	end else begin
		if (poll_tmr != 0) poll_tmr <= poll_tmr - 1'd1;
		if (txr_tmr != 0) txr_tmr <= txr_tmr - 1'd1;
		if (tx_pend && !tx_room && tx_wait != TXWAIT) tx_wait <= tx_wait + 1'd1;
		if (bit_tick && pace != 15'd0) pace <= pace - 15'd1;

		case (st)
		// ---- one mailbox word, then nret
		S_NB: if (nb_ack) begin n_req <= 1'b0; n_rd <= nb_rdata; st <= nret; end

		// ---- start-up: MAGIC off, GEN, the pointers, MAC, MAGIC last
		S_BOOT: if (n_req) begin
			if (nb_ack) n_req <= 1'b0;            // the word that was in flight at reset
		end else begin
			bk <= bk + 3'd1;
			case (bk)
			3'd0: nb(NB_MAGIC, 1'b1, 64'd0, S_BOOT);
			3'd1: nb(NB_GEN, 1'b1, {32'd0, gen_v}, S_BOOT);
			3'd2: nb(NB_TXW, 1'b1, 64'd0, S_BOOT);
			3'd3: nb(NB_TXR, 1'b1, 64'd0, S_BOOT);
			3'd4: nb(NB_RXW, 1'b1, 64'd0, S_BOOT);
			3'd5: nb(NB_RXR, 1'b1, 64'd0, S_BOOT);
			3'd6: begin mac_pend <= 1'b0; nb(NB_MAC, 1'b1, mac_w, S_BOOT); end
			default: nb(NB_MAGIC, 1'b1, MAGIC, S_IDLE);
			endcase
		end

		S_IDLE:
			if (mac_pend) begin
				mac_pend <= 1'b0;
				nb(NB_MAC, 1'b1, mac_w, S_IDLE);
			end else if (rxr_pend) begin
				rxr_pend <= 1'b0;
				nb(NB_RXR, 1'b1, {32'd0, rxr}, S_IDLE);
			end else if (tx_pend && (!ena || tlen == 11'd0 || tlen > TXMAX || tx_wait == TXWAIT)) begin
				tx_pend <= 1'b0; tx_free <= 1'b1;   // dropped
			end else if (tx_pend && tx_room) begin
				tp <= 12'd0; st <= S_TXA;
			end else if (tx_pend && txr_tmr == 0) begin
				txr_tmr <= TXPOLL;
				nb(NB_TXR, 1'b0, 64'd0, S_TXR);
			end else if (!rx_full && rxw_c != rxr) begin
				// Off, or out of step (Main's last RX_WPTR from before our start-up): skip to Main's
				if (!ena || rxw_c - rxr > RX_SLOTS) begin
					rxr <= rxw_c;
					nb(NB_RXR, 1'b1, {32'd0, rxw_c}, S_IDLE);
				end else nb(rslot, 1'b0, 64'd0, S_RXHDR);
			end else if (!rx_full && poll_tmr == 0) begin
				poll_tmr <= POLL;
				nb(NB_RXW, 1'b0, 64'd0, S_RXW);
			end

		// ---- TX: the buffer into the slot's words, little-endian (bytes shifted in from the top)
		S_TXA: st <= S_TXB;                       // txb_q <- txb[tp]
		S_TXB: begin
			tw <= tnw;
			tp <= tp + 12'd1;
			if (tp[2:0] == 3'd7)
				nb(tslot + 13'd1 + {4'd0, tp[11:3]}, 1'b1, tnw, (tp + 12'd1 >= {1'b0, tlen}) ? S_TXHDR : S_TXA);
			else st <= S_TXA;
		end
		S_TXHDR: nb(tslot, 1'b1, {53'd0, tlen}, S_TXPTR);
		S_TXPTR: begin
			txw <= txw + 32'd1;
			nb(NB_TXW, 1'b1, {32'd0, txw + 32'd1}, S_TXDONE);
		end
		S_TXDONE: begin tx_pend <= 1'b0; tx_free <= 1'b1; st <= S_IDLE; end
		S_TXR: begin txr_c <= n_rd[31:0]; st <= S_IDLE; end

		// ---- RX
		S_RXW: begin rxw_c <= n_rd[31:0]; st <= S_IDLE; end
		S_RXHDR:
			if (n_rd[10:0] < RXMIN || n_rd[10:0] > RXMAX) begin
				rxr <= rxr + 32'd1;                 // skipped
				nb(NB_RXR, 1'b1, {32'd0, rxr + 32'd1}, S_IDLE);
			end else begin
				rlen <= n_rd[10:0];
				pace <= ({4'd0, n_rd[10:0]} + 15'd20) << 3;
				rj <= 8'd0; rk <= 3'd0;
				nb(rslot + 13'd1, 1'b0, 64'd0, S_RXBYTE);
			end
		S_RXBYTE: begin
			rxb_we <= 1'b1; rxb_wa <= {rj, rk}; rxb_wd <= n_rd[7:0];
			n_rd <= {8'd0, n_rd[63:8]};
			rk <= rk + 3'd1;
			if (rk == 3'd7) begin
				rj <= rj + 8'd1;
				if ((({4'd0, rj} + 12'd1) << 3) >= {1'b0, rlen}) begin rx_full <= 1'b1; st <= S_IDLE; end
				else nb(rslot + 13'd2 + {5'd0, rj}, 1'b0, 64'd0, S_RXBYTE);
			end
		end
		default: st <= S_IDLE;
		endcase

		// the LANCE's side
		if (mac_stb) mac_pend <= 1'b1;
		if (tx_send && tx_free) begin
			tx_free <= 1'b0; tx_pend <= 1'b1; tlen <= tx_len; tx_wait <= {TWW{1'b0}};
		end
		if (rx_done && rx_full) begin
			rx_full <= 1'b0; rxr <= rxr + 32'd1; rxr_pend <= 1'b1;
		end
	end
end

endmodule
