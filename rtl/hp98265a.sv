//============================================================================
//  hp98265a — HP 98265A SCSI interface (select code 14, $6E0000) with its
//  MB87030 SPC, two SCSI disks (IDs 0 and 1) and a CD-ROM (ID 2) on the
//  card's bus, the three served by one shared target engine.
//  Card registers from MAME bus/hp_dio/hp98265a.cpp; the SPC and the disks
//  are rtl/scsi/ (mb87030.sv, scsi_target.sv; docs/reference/scsi.md).
//
//  Registers (16-bit words at the card base; byte offset in reg_off):
//    +0  read $0007 (ID) / write: card reset (SPC reset pulse)
//    +2  control: write bit 7 IE, bits 1:0 DMA channel enables (DE0/DE1);
//        read control | IRQ<<6 | (level-3)<<4
//    +4  read the SCSI data bus / write the SCSI control lines directly
//    +6  read $88 (flush / configuration)
//    +$20..+$3F  SPC register n on the odd byte of word $10+n
//  Interrupt level 4 (switch SW1 = 1, MAME's default).  The SPC's DREQ goes
//  to DMA channel 0 and/or 1 as DE0/DE1 allow; an acknowledge on a channel
//  that is not enabled is ignored (reads $FF).
//
//  Targets: MiSTer hps_io block interface (WIDE, 512-byte blocks), one slot
//  per ID, packed {CD (ID 2), disk 1, disk 0}.  The CD reads flat 2048-byte
//  sectors (Main presents CUE/CHD that way) at 512 or 2048-byte logical
//  blocks.
//============================================================================

module hp98265a
(
	input             clk,
	input             reset,

	input             reg_cs,
	input             reg_we,
	input      [10:1] reg_off,            // word address within the card window
	input       [1:0] reg_be,
	input      [15:0] reg_din,
	output reg [15:0] reg_dout,

	output            irq,                // level 4
	output      [1:0] dmar,
	input             dack_rd,
	input             dack_wr,
	input             dack_ch,
	input       [7:0] dack_wdata,
	output      [7:0] dack_rdata,

	input       [2:0] img_mounted,
	input      [63:0] img_size,           // shared (sampled on each one's mount pulse)
	input             img_readonly,
	output     [95:0] sd_lba,             // {CD, disk 1, disk 0}
	output      [2:0] sd_rd,
	output      [2:0] sd_wr,
	input       [2:0] sd_ack,
	input       [7:0] sd_buff_addr,
	input      [15:0] sd_buff_dout,
	input             sd_buff_wr,
	output     [47:0] sd_buff_din         // {CD, disk 1, disk 0}
);

reg  [7:0] control;
reg        card_reset;

wire       is_spc = reg_off[10:6] == 5'd0 && reg_off[5];   // byte offsets $20-$3F
wire [3:0] spc_rs = reg_off[4:1];
wire [7:0] spc_dout;
wire       spc_irq, spc_dreq;
wire [7:0] spc_dack_dout;

// ---- the SCSI bus: the SPC and the targets, wired-OR ----
wire [7:0] d_spc, d_tgt;
wire [8:0] c_spc, c_tgt;                   // {rst, atn, sel, bsy, ack, req, msg, cd, io}
wire [7:0] bus_d = d_spc | d_tgt;
wire [8:0] bus_c = c_spc | c_tgt;

wire       de_ok = dack_ch ? control[1] : control[0];

mb87030 spc (
	.clk(clk),
	.reset(reset || card_reset),
	.cs(reg_cs && is_spc && reg_be[0]),
	.we(reg_we),
	.rs(spc_rs),
	.din(reg_din[7:0]),
	.dout(spc_dout),
	.irq(spc_irq),
	.dreq(spc_dreq),
	.dack_rd(dack_rd && de_ok),
	.dack_dout(spc_dack_dout),
	.dack_wr(dack_wr && de_ok),
	.dack_din(dack_wdata),
	// register 2 write: REQ, ACK, BSY, MSG, C/D, I/O in MAME's S_* order
	.ext_ctrl_wr(reg_cs && reg_we && !is_spc && reg_off[10:1] == 10'd2),
	.ext_ctrl({1'b0, 1'b0, reg_din[6], reg_din[7], 1'b0, reg_din[3], reg_din[2], reg_din[1], reg_din[0]}),
	.scsi_data_o(d_spc),
	.scsi_rst_o(c_spc[8]), .scsi_atn_o(c_spc[7]), .scsi_sel_o(c_spc[6]), .scsi_bsy_o(c_spc[5]),
	.scsi_ack_o(c_spc[4]), .scsi_req_o(c_spc[3]), .scsi_msg_o(c_spc[2]), .scsi_cd_o(c_spc[1]), .scsi_io_o(c_spc[0]),
	.scsi_data_i(bus_d),
	.scsi_rst_i(bus_c[8]), .scsi_atn_i(bus_c[7]), .scsi_sel_i(bus_c[6]), .scsi_bsy_i(bus_c[5]),
	.scsi_ack_i(bus_c[4]), .scsi_req_i(bus_c[3]), .scsi_msg_i(bus_c[2]), .scsi_cd_i(bus_c[1]), .scsi_io_i(bus_c[0])
);

// IDs 0-2 behind one shared target engine; ID 2 is the CD-ROM
scsi_target #(.UNITS(3), .CDROM(3'b100)) targets (
	.clk(clk),
	.reset(reset),
	.scsi_data_o(d_tgt),
	.scsi_rst_o(c_tgt[8]), .scsi_atn_o(c_tgt[7]), .scsi_sel_o(c_tgt[6]), .scsi_bsy_o(c_tgt[5]),
	.scsi_ack_o(c_tgt[4]), .scsi_req_o(c_tgt[3]), .scsi_msg_o(c_tgt[2]), .scsi_cd_o(c_tgt[1]), .scsi_io_o(c_tgt[0]),
	.scsi_data_i(bus_d),
	.scsi_rst_i(bus_c[8]), .scsi_atn_i(bus_c[7]), .scsi_sel_i(bus_c[6]), .scsi_bsy_i(bus_c[5]),
	.scsi_ack_i(bus_c[4]), .scsi_req_i(bus_c[3]), .scsi_msg_i(bus_c[2]), .scsi_cd_i(bus_c[1]), .scsi_io_i(bus_c[0]),
	.img_mounted(img_mounted),
	.img_size(img_size),
	.img_readonly(img_readonly),
	.sd_lba(sd_lba),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_wr(sd_buff_wr),                // qualified inside by the connected unit's sd_ack
	.sd_buff_din(sd_buff_din)
);

assign irq        = control[7] && spc_irq;
assign dmar       = {control[1] && spc_dreq, control[0] && spc_dreq};
assign dack_rdata = de_ok ? spc_dack_dout : 8'hFF;

always @(*) begin
	reg_dout = 16'hFFFF;
	if (is_spc) reg_dout = {8'hFF, spc_dout};
	else case (reg_off[10:1])
	10'd0: reg_dout = 16'h0007;
	10'd1: reg_dout = {8'h00, control[7], spc_irq, 2'd1, control[3:0]};
	10'd2: reg_dout = {8'h00, bus_d};
	10'd3: reg_dout = 16'h0088;
	default: reg_dout = 16'hFFFF;
	endcase
end

always @(posedge clk) begin
	card_reset <= 1'b0;
	if (reset) control <= 8'h00;
	else if (reg_cs && reg_we && !is_spc) begin
		if (reg_off[10:1] == 10'd0) begin control <= 8'h00; card_reset <= 1'b1; end
		if (reg_off[10:1] == 10'd1 && reg_be[0]) control <= reg_din[7:0] & 8'h8F;
	end
end

endmodule
