//============================================================================
//  lance — AMD Am7990 LANCE for the HP 98643A LAN card.
//
//  Behaviour follows MAME machine/am79c90.cpp (the 7990 variant), with the
//  notes of docs/reference/lan_98643.md:
//    - RAP (2 bits) and CSR0-3.  CSR1-3 are written only while STOPped.
//      STOP (when not already stopped) resets the chip: CSR0 = STOP, CSR3,
//      RAP and MODE = 0.  INIT, STRT and TDMD may arrive in one write (the
//      boot ROM's self-test does): init, then start, then a transmit poll.
//    - INIT reads the 12-word initialisation block at CSR2:CSR1; IDON (and
//      the deferred STRT/TDMD/INEA of the same write) follow IDON_DLY clocks
//      after INIT, about MAME's 96 LANCE clocks.
//    - transmit: TMD ring walk with buffer chaining, FCS appended unless
//      MODE.DTCR, BABL over 1518 bytes, BUFF|UFLO and TXON off when a
//      chained descriptor is not OWNed; polled on STRT, TDMD, completion and
//      every POLL clocks (1.6 ms).
//    - receive: PROM / unicast PADR / broadcast / LADRF hash (CRC-32 of the
//      destination, bits 31:26 of the un-inverted register) filter, RMD ring
//      walk with chaining (STP, ENP, MCNT incl. FCS), MISS when the current
//      RMD is not OWNed, ERR|BUFF when a chained one is not, FCS check except
//      in loopback without DTCR.
//    - loopback (MODE.LOOP, with or without INTL): the frame (8-32 bytes, plus
//      the FCS) goes straight to the receiver; LOOP+COLL+INTL is a forced
//      collision (TMD1.ERR, TMD3.RTRY, no receive).  CERR (SQE) and MERR are
//      never set; collisions, retries and TDR are not modelled.
//
//  Memory: the card's 16 KB RAM (big-endian 16-bit words, LANCE address
//  bits 23:14 ignored) on a word port with a registered read: m_rdata is
//  ram[m_addr] two clocks after m_addr is set.  Descriptors and the init
//  block are native words; frame bytes follow CSR3.BSWP (1: byte at address
//  A is the big-endian byte at A, as the HP drivers and boot ROM set it).
//
//  The wire (lan_wire): a transmitted frame is written byte by byte into the
//  wire's TX buffer (tx_we/tx_addr/tx_wdata) and handed over with tx_send and
//  its length without FCS; a received frame (with FCS) is read from the
//  wire's RX buffer (rx_addr -> rx_q two clocks later) and released with
//  rx_done.
//============================================================================

module lance
#(
	parameter POLL     = 52800,                // TX poll period (1.6 ms at 33 MHz)
	parameter IDON_DLY = 160                   // clocks from INIT to IDON
)
(
	input             clk,
	input             reset,                   // system or card reset

	// host register port: a1 = 0 RDP, 1 RAP
	input             reg_cs,
	input             reg_we,
	input             reg_a1,
	input      [15:0] reg_din,
	output     [15:0] reg_dout,
	output            intr,                    // CSR0.INTR && INEA

	// card RAM (word address = LANCE address 13:1)
	output reg [12:0] m_addr,
	output reg        m_we,
	output reg  [1:0] m_be,                    // [1] = D15:8 (even byte)
	output reg [15:0] m_wdata,
	input      [15:0] m_rdata,

	// the wire
	input             tx_ready,
	output reg        tx_we,
	output reg [10:0] tx_addr,
	output reg  [7:0] tx_wdata,
	output reg        tx_send,
	output reg [10:0] tx_len,
	input             rx_avail,
	input      [10:0] rx_len,
	output reg [10:0] rx_addr,
	input       [7:0] rx_q,
	output reg        rx_done,

	output reg [47:0] padr,                    // [47:40] = first byte on the wire
	output reg        padr_stb
);

// ---- CRC-32 (reflected, poly $EDB88320), one byte ----
function [31:0] crc_byte(input [31:0] c, input [7:0] b);
	integer i;
	reg [31:0] x;
	begin
		x = c;
		for (i = 0; i < 8; i = i + 1)
			x = (x[0] ^ b[i]) ? ((x >> 1) ^ 32'hEDB88320) : (x >> 1);
		crc_byte = x;
	end
endfunction

// byte A of a word, and the lanes to write it, by BSWP
function [7:0] pick(input [15:0] w, input a0, input bswp);
	pick = (a0 ^ !bswp) ? w[7:0] : w[15:8];
endfunction
function [1:0] lane(input a0, input bswp);
	lane = (a0 ^ !bswp) ? 2'b01 : 2'b10;
endfunction

// buffer length: two's complement BCNT, 0 = 4096
function [12:0] blen(input [15:0] d);
	blen = 13'h1000 - {1'b0, d[11:0]};
endfunction

localparam [15:0] OWN = 16'h8000, ERR = 16'h4000, STP = 16'h0200, ENP = 16'h0100;
localparam [15:0] R_CRC = 16'h0800, R_BUFF = 16'h0400;
localparam [15:0] T_BUFF = 16'h8000, T_UFLO = 16'h4000, T_RTRY = 16'h0400;

// ---- registers ----
reg  [1:0] rap;
reg [15:0] csr1, csr2;
reg  [2:0] csr3;
reg        babl, miss, rint, tint, idon, inea, rxon, txon, tdmd, stop, strt, init;
reg        idone;                              // MAME m_idon: an INIT has completed
wire       c0_err  = babl | miss;
wire       c0_intr = babl | miss | rint | tint | idon;
wire [15:0] csr0 = {c0_err, babl, 1'b0, miss, 1'b0, rint, tint, idon,
                    c0_intr, inea, rxon, txon, tdmd, stop, strt, init};
assign intr = c0_intr && inea;

assign reg_dout = reg_a1 ? {14'd0, rap} :
                  rap == 2'd0 ? csr0 : rap == 2'd1 ? {csr1[15:1], 1'b0} :
                  rap == 2'd2 ? csr2 : {13'd0, csr3};

reg [15:0] mode;
reg [63:0] ladrf;
reg [23:0] rdra, tdra;
reg  [2:0] rlen, tlen;
reg  [6:0] rpos, tpos;
wire [6:0] rmask = 7'h7F >> (3'd7 - rlen);
wire [6:0] tmask = 7'h7F >> (3'd7 - tlen);
wire [23:0] r_desc = rdra + {14'd0, rpos, 3'd0};
wire [23:0] t_desc = tdra + {14'd0, tpos, 3'd0};
wire [23:0] r_next = rdra + {14'd0, (rpos + 7'd1) & rmask, 3'd0};
wire [23:0] t_next = tdra + {14'd0, (tpos + 7'd1) & tmask, 3'd0};
wire        bswp = csr3[2];
wire        m_loop = mode[2], m_dtcr = mode[3], m_coll = mode[4], m_intl = mode[6], m_prom = mode[15];

// loopback frame (up to 32 bytes + FCS)
reg  [7:0] lb [0:63];
reg  [6:0] lb_len;
reg        lb_pend;
reg        lb_tint;                            // loopback TINT, raised with the RINT

// ---- sequencer ----
localparam [5:0]
	S_IDLE  = 6'd0,  S_MRD1  = 6'd1,  S_MRD2  = 6'd2,  S_SRC1  = 6'd3,  S_SRC2  = 6'd4,
	S_INIT  = 6'd5,  S_INIT2 = 6'd6,  S_INITW = 6'd7,
	S_TXP   = 6'd8,  S_TXP2  = 6'd9,  S_TXD0  = 6'd10, S_TXD2  = 6'd11, S_TXB   = 6'd12,
	S_TXB2  = 6'd13, S_TXNX  = 6'd14, S_TXEND = 6'd15, S_TXFCS = 6'd16, S_TXCMP = 6'd17,
	S_TXT3  = 6'd18,
	S_RX    = 6'd20, S_RXH   = 6'd21, S_RXF   = 6'd22, S_RXM1  = 6'd23, S_RXD0  = 6'd24,
	S_RXD2  = 6'd25, S_RXB   = 6'd26, S_RXB2  = 6'd27, S_RXNX  = 6'd28, S_RXEND = 6'd29,
	S_RXM3  = 6'd30, S_RXFIN = 6'd31, S_RXDRP = 6'd32, S_RXDR2 = 6'd33,
	S_TXNX2 = 6'd34, S_RXNX2 = 6'd35;

reg  [5:0] st, ret;
reg [15:0] w;                                  // word read (S_MRD2)
reg  [7:0] sb;                                 // source byte read (S_SRC2)
reg [10:0] sidx;
reg  [3:0] icnt;                               // init word
reg [15:0] iblk [0:11];
reg  [7:0] dly;
reg        d_strt, d_tdmd, d_inea;             // deferred to the end of INIT
reg        init_req, poll_req;
reg [16:0] poll_cnt;

reg [15:0] md1, md3;                           // current RMD1/TMD1, TMD3
reg [23:0] bufa;                               // buffer byte address
reg [12:0] bcnt, bk;                           // buffer length, byte within it
reg [11:0] flen;                               // frame length so far / to receive
reg [31:0] crc;
reg [47:0] dst;
reg  [2:0] hn;                                 // header bytes read
reg        src_lb;                             // receiving the loopback frame
reg        drop;                               // wire frame: just release it
reg [11:0] rlen_f;                             // frame length (incl. FCS)

wire [11:0] src_len = src_lb ? {5'd0, lb_len} : {1'b0, rx_len};
wire        bcast   = &dst;
wire        hash_hit = ladrf[crc[31:26]];
wire        accept  = m_prom || (dst[40] ? (bcast || hash_hit) : (dst == padr));

task automatic mread(input [23:0] a, input [5:0] r);
	begin m_addr <= a[13:1]; st <= S_MRD1; ret <= r; end
endtask
task automatic mwrite(input [23:0] a, input [15:0] d, input [1:0] be);
	begin m_addr <= a[13:1]; m_wdata <= d; m_be <= be; m_we <= 1'b1; end
endtask
task automatic sread(input [10:0] i, input [5:0] r);
	begin rx_addr <= i; sidx <= i; st <= S_SRC1; ret <= r; end
endtask

// the deferred part of a CSR0 write that started an INIT, or the immediate one
task automatic do_start(input s, input t, input ie);
	begin
		if (s && !strt) begin
			strt <= 1'b1; stop <= 1'b0;
			rxon <= !mode[0]; txon <= !mode[1];
			poll_req <= 1'b1;
		end
		if (t && !tdmd) begin tdmd <= 1'b1; poll_req <= 1'b1; end
	end
endtask

always @(posedge clk) begin
	m_we     <= 1'b0;
	tx_we    <= 1'b0;
	tx_send  <= 1'b0;
	rx_done  <= 1'b0;
	padr_stb <= 1'b0;

	if (reset) begin
		rap <= 0; csr3 <= 0; mode <= 0;
		{babl, miss, rint, tint, idon, inea, rxon, txon, tdmd, strt, init} <= 0;
		stop <= 1'b1; idone <= 1'b0;
		st <= S_IDLE; init_req <= 0; poll_req <= 0; poll_cnt <= 0; lb_pend <= 0; lb_tint <= 0;
	end
	else begin
		// ---- TX poll timer ----
		if (txon) begin
			if (poll_cnt == POLL - 1) begin poll_cnt <= 0; poll_req <= 1'b1; end
			else poll_cnt <= poll_cnt + 17'd1;
		end
		else poll_cnt <= 0;

		// ---- sequencer (register writes below override what it sets) ----
		case (st)
		S_MRD1: st <= S_MRD2;
		S_MRD2: begin w <= m_rdata; st <= ret; end
		S_SRC1: st <= S_SRC2;
		S_SRC2: begin sb <= src_lb ? lb[sidx[5:0]] : rx_q; st <= ret; end

		S_IDLE:
			if (init_req) begin
				init_req <= 1'b0; icnt <= 0; dly <= 0; st <= S_INIT;
			end
			else if (lb_pend) begin
				src_lb <= 1'b1; st <= S_RX;
			end
			else if (poll_req && txon && (m_loop || tx_ready)) begin
				poll_req <= 1'b0; tdmd <= 1'b0;
				mread(t_desc + 24'd2, S_TXP2);
			end
			else if (poll_req && !txon)
				poll_req <= 1'b0;
			else if (rx_avail) begin
				src_lb <= 1'b0;
				if (!rxon || m_loop || rx_len < 11'd64) begin
					rx_done <= 1'b1; st <= S_RXDRP;    // dropped
				end
				else st <= S_RX;
			end
		S_RXDRP: st <= S_RXDR2;                 // rx_avail falls after rx_done
		S_RXDR2: st <= S_IDLE;

		// ---- INIT: 12 words ----
		S_INIT: begin
			mread({csr2[7:0], csr1[15:1], 1'b0} + {19'd0, icnt, 1'b0}, S_INIT2);
			if (dly != 8'hFF) dly <= dly + 8'd3;
		end
		S_INIT2: begin
			iblk[icnt] <= w;
			if (dly != 8'hFF) dly <= dly + 8'd1;
			if (icnt == 4'd11) st <= S_INITW;
			else begin icnt <= icnt + 4'd1; st <= S_INIT; end
		end
		S_INITW:
			if (dly >= IDON_DLY[7:0]) begin
				mode  <= iblk[0];
				padr  <= {iblk[1][7:0], iblk[1][15:8], iblk[2][7:0], iblk[2][15:8], iblk[3][7:0], iblk[3][15:8]};
				padr_stb <= 1'b1;
				ladrf <= {iblk[7], iblk[6], iblk[5], iblk[4]};
				rdra  <= {iblk[9][7:0], iblk[8][15:3], 3'd0};  rlen <= iblk[9][15:13];
				tdra  <= {iblk[11][7:0], iblk[10][15:3], 3'd0}; tlen <= iblk[11][15:13];
				rpos <= 0; tpos <= 0;
				idon <= 1'b1; init <= 1'b1; stop <= 1'b0; idone <= 1'b1;
				// the rest of the CSR0 write: start, transmit demand, INEA
				if (d_strt && !strt) begin
					strt <= 1'b1;
					rxon <= !iblk[0][0]; txon <= !iblk[0][1];
					poll_req <= 1'b1;
				end
				if (d_tdmd) begin tdmd <= 1'b1; poll_req <= 1'b1; end
				inea <= d_inea;
				st <= S_IDLE;
			end
			else dly <= dly + 8'd1;

		// ---- transmit ----
		S_TXP2:                                 // w = TMD1
			if (!w[15]) st <= S_IDLE;
			else if ((w & STP) == 16'd0) begin           // OWN without STP: skip it
				mwrite(t_desc + 24'd2, w & ~OWN, 2'b11);
				tpos <= (tpos + 7'd1) & tmask;
				st <= S_IDLE;
			end
			else begin
				md1 <= w; md3 <= 0; flen <= 0; crc <= 32'hFFFF_FFFF;
				mread(t_desc, S_TXD0);
			end
		S_TXD0: begin bufa <= {md1[7:0], w}; mread(t_desc + 24'd4, S_TXD2); end
		S_TXD2: begin
			bcnt <= blen(w); bk <= 0; md1 <= md1 & ~OWN;
			st <= S_TXB;
		end
		S_TXB:                                  // next byte: fetch its word if needed
			if (bk == 0 || !bufa[0]) mread(bufa, S_TXB2);
			else st <= S_TXB2;
		S_TXB2: begin
			if (m_loop) begin
				if (flen < 12'd64) lb[flen[5:0]] <= pick(w, bufa[0], bswp);
			end
			else if (flen < 12'd2048) begin
				tx_we <= 1'b1; tx_addr <= flen[10:0]; tx_wdata <= pick(w, bufa[0], bswp);
			end
			crc  <= crc_byte(crc, pick(w, bufa[0], bswp));
			if (flen != 12'hFFF) flen <= flen + 12'd1;
			bufa <= bufa + 24'd1;
			bk   <= bk + 13'd1;
			if (bk + 13'd1 == bcnt) begin
				if (md1[8]) st <= S_TXEND;
				else if (tlen == 0) begin         // a one-entry ring has no next
					w <= md1; st <= S_TXNX;
				end
				else mread(t_next + 24'd2, S_TXNX);
			end
			else st <= S_TXB;
		end
		S_TXNX:                                 // w = next TMD1
			if (w[15]) begin
				mwrite(t_desc + 24'd2, md1, 2'b11);
				tpos <= (tpos + 7'd1) & tmask;
				md1 <= w;
				st <= S_TXNX2;                    // the read takes the next clock
			end
			else begin
				md1 <= md1 | ERR;
				md3 <= T_BUFF | T_UFLO;
				txon <= 1'b0;
				st <= S_TXT3;                     // write TMD3, then finish
			end
		S_TXNX2: mread(t_desc, S_TXD0);         // the new current descriptor
		S_TXT3: begin
			mwrite(t_desc + 24'd6, md3, 2'b11);
			st <= S_TXEND;
		end
		S_TXEND: begin
			if (flen > 12'd1518) babl <= 1'b1;
			if (m_loop) begin
				if (m_coll && m_intl) begin       // forced collision
					md1 <= md1 | ERR; md3 <= md3 | T_RTRY;
					mwrite(t_desc + 24'd6, md3 | T_RTRY, 2'b11);
					st <= S_TXCMP;
				end
				else if (flen < 12'd8 || flen > 12'd32) begin
					md1 <= md1 | ERR; st <= S_TXCMP;
				end
				else if (!m_dtcr) begin
					bk <= 0; st <= S_TXFCS;           // append the FCS
				end
				else begin
					lb_len <= flen[6:0]; lb_pend <= 1'b1; st <= S_TXCMP;
				end
			end
			else begin
				// the wire takes the frame without its FCS
				if (flen <= 12'd2047 && !(m_dtcr && flen < 12'd4)) begin
					tx_send <= 1'b1;
					tx_len  <= m_dtcr ? flen[10:0] - 11'd4 : flen[10:0];
				end
				st <= S_TXCMP;
			end
		end
		S_TXFCS: begin
			lb[flen[5:0] + {4'd0, bk[1:0]}] <= ~crc[{bk[1:0], 3'b000} +: 8];
			bk <= bk + 13'd1;
			if (bk[1:0] == 2'd3) begin
				lb_len <= flen[6:0] + 7'd4; lb_pend <= 1'b1; st <= S_TXCMP;
			end
		end
		S_TXCMP: begin
			mwrite(t_desc + 24'd2, md1, 2'b11);
			tpos <= (tpos + 7'd1) & tmask;
			// a looped frame's TINT waits for its receive (HP-UX allows only
			// 30 status polls from TINT to RINT)
			if (lb_pend) lb_tint <= 1'b1; else tint <= 1'b1;
			poll_req <= 1'b1;                     // back-to-back
			st <= S_IDLE;
		end

		// ---- receive (src_lb: the loopback frame, else the wire's) ----
		S_RX: begin
			rlen_f <= src_len; hn <= 0; crc <= 32'hFFFF_FFFF;
			sread(11'd0, S_RXH);
		end
		S_RXH: begin                            // destination address
			dst <= {dst[39:0], sb};
			crc <= crc_byte(crc, sb);
			if (hn == 3'd5) st <= S_RXF;
			else begin hn <= hn + 3'd1; sread({8'd0, hn + 3'd1}, S_RXH); end
		end
		S_RXF:
			if (!accept) st <= S_RXFIN;          // filtered: no RINT
			else mread(r_desc + 24'd2, S_RXM1);
		S_RXM1:                                 // w = RMD1
			if (!w[15]) begin
				miss <= 1'b1; rint <= 1'b1; st <= S_RXFIN;
			end
			else begin
				md1 <= w | STP; flen <= 0; crc <= 32'hFFFF_FFFF;
				mread(r_desc, S_RXD0);
			end
		S_RXD0: begin bufa <= {md1[7:0], w}; mread(r_desc + 24'd4, S_RXD2); end
		S_RXD2: begin
			bcnt <= blen(w); bk <= 0;
			sread(flen[10:0], S_RXB);
		end
		S_RXB: begin                            // sb = frame byte flen
			mwrite(bufa, {sb, sb}, lane(bufa[0], bswp));
			crc  <= crc_byte(crc, sb);
			flen <= flen + 12'd1;
			bufa <= bufa + 24'd1;
			bk   <= bk + 13'd1;
			st   <= S_RXB2;
		end
		S_RXB2:
			if (flen == rlen_f) begin
				md1 <= md1 & ~OWN | ENP |
				       (((!m_loop || m_dtcr) && crc != 32'hDEBB20E3) ? (ERR | R_CRC) : 16'd0);
				st <= S_RXEND;
			end
			else if (bk == bcnt) begin           // buffer full: chain
				md1 <= md1 & ~OWN;
				if (rlen == 0) begin w <= md1 & ~OWN; st <= S_RXNX; end
				else mread(r_next + 24'd2, S_RXNX);
			end
			else sread(flen[10:0], S_RXB);
		S_RXNX:                                 // w = next RMD1
			if (w[15]) begin
				mwrite(r_desc + 24'd2, md1, 2'b11);
				rpos <= (rpos + 7'd1) & rmask;
				md1 <= w;
				st <= S_RXNX2;                    // the read takes the next clock
			end
			else begin
				md1 <= md1 | ERR | R_BUFF;
				st <= S_RXEND;
			end
		S_RXNX2: mread(r_desc, S_RXD0);
		S_RXEND: begin
			mwrite(r_desc + 24'd2, md1, 2'b11);
			st <= S_RXM3;
		end
		S_RXM3: begin
			mwrite(r_desc + 24'd6, md1[14] ? 16'd0 : {4'd0, flen}, 2'b11);
			rpos <= (rpos + 7'd1) & rmask;
			rint <= 1'b1;
			st <= S_RXFIN;
		end
		S_RXFIN: begin
			if (src_lb) begin lb_pend <= 1'b0; if (lb_tint) tint <= 1'b1; lb_tint <= 1'b0; end
			else rx_done <= 1'b1;
			st <= src_lb ? S_IDLE : S_RXDRP;
		end
		default: st <= S_IDLE;
		endcase

		// ---- host register writes ----
		if (reg_cs && reg_we) begin
			if (reg_a1) rap <= reg_din[1:0];
			else case (rap)
			2'd0:
				if (reg_din[2]) begin
					if (!stop) begin               // STOP: reset the chip
						rap <= 0; csr3 <= 0; mode <= 0;
						{babl, miss, rint, tint, idon, inea, rxon, txon, tdmd, strt, init} <= 0;
						stop <= 1'b1; idone <= 1'b0;
						st <= S_IDLE; init_req <= 0; poll_req <= 0; lb_pend <= 0; lb_tint <= 0;
						// a wire frame being received is dropped from S_IDLE (RXON off)
					end
				end
				else begin
					if (reg_din[14]) babl <= 1'b0;
					if (reg_din[12]) miss <= 1'b0;
					if (reg_din[10]) rint <= 1'b0;
					if (reg_din[9])  tint <= 1'b0;
					if (reg_din[8])  idon <= 1'b0;
					if (reg_din[0] && !init && stop) begin
						// INIT: the rest of this write waits for IDON
						init_req <= 1'b1;
						d_strt <= reg_din[1]; d_tdmd <= reg_din[3]; d_inea <= reg_din[6];
					end
					else begin
						if (reg_din[0] && !init) begin
							if (idone) idon <= 1'b1; else init <= 1'b1;
						end
						do_start(reg_din[1], reg_din[3], reg_din[6]);
						if (!stop || (reg_din[1] && !strt)) inea <= reg_din[6];
					end
				end
			2'd1: if (stop) csr1 <= reg_din;
			2'd2: if (stop) csr2 <= reg_din;
			2'd3: if (stop) csr3 <= reg_din[2:0];
			endcase
		end
	end
end

endmodule
