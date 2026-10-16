//============================================================================
//  hp98643 — HP 98643A LAN card (select code 21, $750000-$75FFFF): an
//  Am7990 LANCE (rtl/lance.sv) mastering 16 KB of card RAM, and a NOVRAM
//  with the station address.  Reference: MAME bus/hp_dio/hp98643.cpp and
//  docs/reference/lan_98643.md.
//
//  Window (byte offsets):
//    +$0000  read $0015 (ID); any write resets the card and the LANCE
//    +$0003  status/control: 7 IE (rw), 6 IP = LANCE INTR && INEA (ro, raw:
//            visible with IE off, which the boot ROM's self-test needs),
//            5:4 interrupt level - 3 (level 5), 3 LOCK (rw), 2 ACK (ro: set
//            by a write with LOCK and by any LANCE register access, cleared
//            only by a card reset), 1 0, 0 1 (thin coax)
//    +$4000  LANCE RDP, +$4002 RAP (mirrored through $7FFF)
//    +$8000-$BFFF  card RAM, big-endian 16-bit words.  The LANCE sees the
//            same RAM at any address modulo 16 KB (NetBSD uses 0, the boot
//            ROM $8000).
//    +$C000-$FFFF  NOVRAM, 64 nibbles (one per word in D3:0, reads $FFFx),
//            mirrored every $80; byte n at +$C000 + 4n high nibble first, two
//            16-byte copies: 0 copy select (0), 1 0, 2-7 the station address,
//            8-14 0, 15 the sum of bytes 1-14.  Writable (HP-UX's self-test
//            writes patterns and checks them); reset and the card reset
//            recall the image, as the NOVRAM's EEPROM recall does.
//
//  Card RAM reads come from block RAM: reg_wait holds a read for the clock
//  the RAM needs (it depends on reg_sel/reg_we/reg_off only, not reg_cs).
//============================================================================

module hp98643
#(
	parameter [47:0] MAC      = 48'h08_00_09_38_50_01,
	parameter        POLL     = 52800,
	parameter        IDON_DLY = 160
)
(
	input             clk,
	input             reset,

	input             reg_sel,               // an access is pending
	input             reg_cs,                // ... and takes place this clock
	input             reg_we,
	input      [15:1] reg_off,               // word address within the window
	input       [1:0] reg_be,                // [1] = D15:8 (even byte)
	input      [15:0] reg_din,
	output reg [15:0] reg_dout,
	output            reg_wait,
	output            irq,                   // level 5

	input             tx_ready,
	output            tx_we,
	output     [10:0] tx_addr,
	output      [7:0] tx_wdata,
	output            tx_send,
	output     [10:0] tx_len,
	input             rx_avail,
	input      [10:0] rx_len,
	output     [10:0] rx_addr,
	input       [7:0] rx_q,
	output            rx_done,

	output     [47:0] padr,
	output            padr_stb
);

wire is_id   = reg_off[15:14] == 2'b00 && !reg_off[1];
wire is_sc   = reg_off[15:14] == 2'b00 &&  reg_off[1];
wire is_lan  = reg_off[15:14] == 2'b01;
wire is_ram  = reg_off[15:14] == 2'b10;
wire is_nov  = reg_off[15:14] == 2'b11;

// ---- status/control, card reset ----
reg  ie, lock, ack;
reg  card_rst;
wire lance_intr;
wire [7:0] sc = {ie, lance_intr, 2'b10, lock, ack, 1'b0, 1'b1};
assign irq = ie && lance_intr;

always @(posedge clk) begin
	card_rst <= 1'b0;
	if (reset || card_rst) begin
		ie <= 1'b0; lock <= 1'b0; ack <= 1'b0;
	end
	else if (reg_cs && reg_we) begin
		if (is_id) card_rst <= 1'b1;
		if (is_sc && reg_be[0]) begin
			ie <= reg_din[7]; lock <= reg_din[3];
			if (reg_din[3]) ack <= 1'b1;
		end
		if (is_lan) ack <= 1'b1;
	end
	else if (reg_cs && is_lan) ack <= 1'b1;
end

// ---- NOVRAM ----
function [7:0] mac_byte(input [3:0] n);
	case (n)
	4'd2: mac_byte = MAC[47:40]; 4'd3: mac_byte = MAC[39:32]; 4'd4: mac_byte = MAC[31:24];
	4'd5: mac_byte = MAC[23:16]; 4'd6: mac_byte = MAC[15:8];  4'd7: mac_byte = MAC[7:0];
	default: mac_byte = 8'h00;
	endcase
endfunction
localparam [7:0] NOV_SUM = MAC[47:40] + MAC[39:32] + MAC[31:24] + MAC[23:16] + MAC[15:8] + MAC[7:0];
function [3:0] nov_init(input [5:0] i);
	reg [7:0] b;
	begin
		b = i[4:1] == 4'd15 ? NOV_SUM : mac_byte(i[4:1]);
		nov_init = i[0] ? b[3:0] : b[7:4];
	end
endfunction

wire [255:0] nov_img;                     // the recalled contents
genvar gi;
generate for (gi = 0; gi < 64; gi = gi + 1) begin : g_nov
	assign nov_img[gi * 4 +: 4] = nov_init(gi);
end endgenerate

reg  [255:0] nov;
wire   [5:0] nov_i = reg_off[6:1];
always @(posedge clk) begin
	if (reset || card_rst)
		nov <= nov_img;
	else if (reg_cs && reg_we && is_nov && reg_be[0])
		nov[{nov_i, 2'b00} +: 4] <= reg_din[3:0];
end
wire [3:0] nov_nib = nov[{nov_i, 2'b00} +: 4];

// ---- card RAM: true dual port, A = host, B = LANCE (rtl/wombat/dpram.v:
// an altsyncram, two 8-bit halves for the byte lanes) ----
wire [15:0] qa, qb;
wire [12:0] a_addr = reg_off[13:1];
wire        a_we   = reg_cs && reg_we && is_ram;
wire [12:0] b_addr;
wire        b_we;
wire  [1:0] b_be;
wire [15:0] b_wdata;

dpram #(.AW(13), .DW(8)) ram_hi (
	.clock(clk),
	.address_a(a_addr), .data_a(reg_din[15:8]), .wren_a(a_we && reg_be[1]), .q_a(qa[15:8]),
	.address_b(b_addr), .data_b(b_wdata[15:8]), .wren_b(b_we && b_be[1]),   .q_b(qb[15:8])
);
dpram #(.AW(13), .DW(8)) ram_lo (
	.clock(clk),
	.address_a(a_addr), .data_a(reg_din[7:0]),  .wren_a(a_we && reg_be[0]), .q_a(qa[7:0]),
	.address_b(b_addr), .data_b(b_wdata[7:0]),  .wren_b(b_we && b_be[0]),   .q_b(qb[7:0])
);

// a read is ready once its address has been on port A for a clock with no
// write in between
reg [12:0] qa_addr;
reg        qa_ok;
always @(posedge clk) begin
	qa_addr <= a_addr;
	qa_ok   <= !a_we;
end
assign reg_wait = reg_sel && !reg_we && is_ram && !(qa_ok && qa_addr == a_addr);

// ---- the LANCE ----
wire [15:0] lance_dout;

lance #(.POLL(POLL), .IDON_DLY(IDON_DLY)) lance (
	.clk(clk),
	.reset(reset || card_rst),
	.reg_cs(reg_cs && is_lan),
	.reg_we(reg_we),
	.reg_a1(reg_off[1]),
	.reg_din(reg_din),
	.reg_dout(lance_dout),
	.intr(lance_intr),
	.m_addr(b_addr),
	.m_we(b_we),
	.m_be(b_be),
	.m_wdata(b_wdata),
	.m_rdata(qb),
	.tx_ready(tx_ready),
	.tx_we(tx_we),
	.tx_addr(tx_addr),
	.tx_wdata(tx_wdata),
	.tx_send(tx_send),
	.tx_len(tx_len),
	.rx_avail(rx_avail),
	.rx_len(rx_len),
	.rx_addr(rx_addr),
	.rx_q(rx_q),
	.rx_done(rx_done),
	.padr(padr),
	.padr_stb(padr_stb)
);

always @(*) begin
	if (is_id)       reg_dout = 16'h0015;
	else if (is_sc)  reg_dout = {8'h00, sc};
	else if (is_lan) reg_dout = lance_dout;
	else if (is_ram) reg_dout = qa;
	else             reg_dout = {12'hFFF, nov_nib};
end

endmodule
