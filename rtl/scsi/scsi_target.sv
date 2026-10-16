//============================================================================
//  scsi_target — SCSI direct-access targets (disks and CD-ROMs) on IDs
//  0 .. UNITS-1, backed by MiSTer block devices, served by one shared
//  protocol engine.
//  Behaviour reference: MAME bus/nscsi/hd.cpp and machine/nscsi_hle.cpp
//  (nscsi_full_device).  See docs/reference/scsi.md.
//
//  Only one target is connected at a time, so one state machine, CDB, set
//  of counters and sector buffer serve every unit.  Kept per unit, because
//  it outlives a connection: the image (mounted / read-only / size), the
//  pending sense, the request lines to hps_io, and for a CD-ROM unit its
//  unit attention, block length and lead-out MSF.  `cur` is the unit that
//  won the selection; everything the engine does applies to it.
//
//  Bus side: responds to a selection carrying the ID bit of any unit (an
//  ID without an image still answers; IDs >= UNITS do not), no arbitration
//  of its own, never reselects.  Takes MESSAGE OUT bytes while ATN is up
//  (IDENTIFY sets the LUN, anything else is ignored), a 6/10/12/16-byte
//  CDB, then runs DATA IN / DATA OUT, STATUS, MESSAGE IN (COMMAND
//  COMPLETE) and releases the bus.  SCSI RST drops everything.
//
//  Commands: TEST UNIT READY, REZERO, REQUEST SENSE, FORMAT UNIT (no-op),
//  READ(6/10), WRITE(6/10), SEEK(6/10), INQUIRY, MODE SELECT(6) (data
//  taken and dropped), RESERVE, RELEASE, MODE SENSE(6) (pages 3, 4, 0x3F),
//  START STOP UNIT, SEND DIAGNOSTIC (parameter data dropped), PREVENT ALLOW,
//  READ CAPACITY, VERIFY(10), SYNCHRONIZE CACHE: all GOOD where they apply.
//  Anything else: CHECK CONDITION, ILLEGAL REQUEST / invalid opcode.  With
//  no image every command but INQUIRY and REQUEST SENSE gets CHECK
//  CONDITION, NOT READY / medium not present.
//
//  Block side (hps_io, WIDE=1, BLKSZ=2), one slot per unit, packed with
//  unit 0 in the low bits.  A disk unit moves up to MAXB 512-byte blocks
//  per request (sd_blk_cnt = blocks - 1), a CD-ROM unit one (the Main
//  fork's CD translation serves 512-byte requests).  sd_lba / sd_blk_cnt
//  are set and the unit's sd_rd / sd_wr raised; the request drops when
//  that unit's sd_ack rises, the transfer is done when it falls.  Words
//  are little-endian: [7:0] is the even (first) byte, and sd_buff_addr
//  counts words across the blocks of one request.  Reads land through
//  sd_buff_wr at sd_buff_addr; for writes sd_buff_din is the buffer word
//  at sd_buff_addr registered one clock later (hps_io samples it many
//  clocks after it moves the address).  One buffer of MAXB blocks, no
//  read-ahead: a READ / WRITE costs one HPS round trip per MAXB blocks
//  (each also one O_SYNC write on Main's side, unless its write buffer
//  takes it).  A new request waits until no unit has one outstanding, so
//  the shared sd_lba (the same on every slot) never moves under a request
//  and the one buffer serves all.
//
//  Image: img_mounted[u] (a pulse) latches img_size / img_readonly for
//  unit u.  The mount state is not cleared by `reset` (the HPS does not
//  mount again after a core reset).
//
//  CDROM[u] = 1: unit u is an HP-300-style SCSI CD-ROM (peripheral type
//  05h, removable, read-only).  The image is a flat run of 2048-byte data
//  sectors.  The logical block length is 512 (what the HP 300 boot ROM and
//  HP-UX expect) and MODE SELECT(6) with a block descriptor switches it to
//  2048 and back; READ / READ CAPACITY / MODE SENSE / READ TOC follow the
//  current length.  Extra commands: READ TOC (format 0, track 1 + lead-out,
//  LBA or MSF), READ SUB-CHANNEL (no audio status), READ HEADER (LBA
//  form).  Writes and FORMAT are refused, audio commands are ILLEGAL
//  REQUEST.  A mount raises UNIT ATTENTION 28h for the next command other
//  than INQUIRY.
//============================================================================

module scsi_target
#(
	parameter             UNITS = 3,             // IDs 0 .. UNITS-1 (1..8)
	parameter [UNITS-1:0] CDROM = {UNITS{1'b0}}, // bit u: unit u is a CD-ROM
	parameter             MAXB  = 32             // disk blocks per HPS request (1..32: hps_io's 16 KB)
)
(
	input             clk,
	input             reset,

	output     [7:0] scsi_data_o,
	output           scsi_bsy_o, scsi_sel_o, scsi_atn_o, scsi_ack_o, scsi_rst_o,
	output           scsi_req_o, scsi_msg_o, scsi_cd_o, scsi_io_o,
	input      [7:0] scsi_data_i,
	input            scsi_bsy_i, scsi_sel_i, scsi_atn_i, scsi_ack_i, scsi_rst_i,
	input            scsi_req_i, scsi_msg_i, scsi_cd_i, scsi_io_i,

	input        [UNITS-1:0] img_mounted,
	input             [63:0] img_size,        // shared, sampled on each mount pulse
	input                    img_readonly,

	output    [32*UNITS-1:0] sd_lba,
	output     [6*UNITS-1:0] sd_blk_cnt,
	output reg   [UNITS-1:0] sd_rd,
	output reg   [UNITS-1:0] sd_wr,
	input        [UNITS-1:0] sd_ack,
	input             [12:0] sd_buff_addr,
	input             [15:0] sd_buff_dout,
	input                    sd_buff_wr,
	output    [16*UNITS-1:0] sd_buff_din
);

localparam       UW    = (UNITS > 4) ? 3 : (UNITS > 2) ? 2 : 1;   // unit index width
localparam [7:0] IDS   = (8'd1 << UNITS) - 8'd1;                   // ID bits we answer

// geometry reported by MODE SENSE: 16 heads x 32 sectors = 512 blocks/cylinder
localparam [7:0] HEADS = 8'd16;
localparam [7:0] SPT   = 8'd32;

// INQUIRY bytes 8..35
localparam [223:0] INQ_DISK = "HP9K385 SCSI DISK       1.0 ";
localparam [223:0] INQ_CD   = "HP9K385 SCSI CD-ROM     1.0 ";

// sense keys / additional sense codes
localparam [3:0] SK_NONE = 4'h0, SK_NOT_READY = 4'h2, SK_ILLEGAL = 4'h5, SK_UNIT_ATT = 4'h6,
                 SK_PROTECT = 4'h7;
localparam [7:0] ASC_NONE = 8'h00, ASC_BAD_OP = 8'h20, ASC_LBA = 8'h21, ASC_BAD_CDB = 8'h24,
                 ASC_LUN = 8'h25, ASC_BAD_PARAM = 8'h26, ASC_WPROT = 8'h27,
                 ASC_CHANGED = 8'h28, ASC_NO_MEDIUM = 8'h3A;

// synthesized data-in sources
localparam [2:0] K_INQ = 3'd0, K_SENSE = 3'd1, K_CAP = 3'd2, K_MSENSE = 3'd3,
                 K_TOC = 3'd4, K_SUBCH = 3'd5, K_HDR = 3'd6;

localparam [4:0] S_IDLE    = 5'd0,  S_SETTLE  = 5'd1,  S_WSEL0   = 5'd2,
                 S_MSGO    = 5'd3,  S_CMD     = 5'd4,  S_EXEC    = 5'd5,
                 S_DIN     = 5'd6,  S_RD_REQ  = 5'd7,  S_RD_WAIT = 5'd8,
                 S_RD_SEND = 5'd9,  S_RD_FETCH= 5'd10, S_DOUT    = 5'd11,
                 S_DOUT_B  = 5'd12, S_WR_REQ  = 5'd13, S_WR_WAIT = 5'd14,
                 S_STAT    = 5'd15, S_MSGI    = 5'd16, S_FREE    = 5'd17,
                 S_TXB     = 5'd18, S_TXW     = 5'd19, S_RXB     = 5'd20,
                 S_RXW     = 5'd21;

// ---- per unit: image, and the CD-ROM lead-out as minutes / seconds /
// frames, worked out after a mount by repeated subtraction (2048-byte
// sectors + the 150-frame pregap) ----
wire    [UNITS-1:0] u_mounted, u_ro;
wire [32*UNITS-1:0] u_blocks;                // image size in 512-byte blocks
wire [24*UNITS-1:0] u_msf;                   // {M, S, F}

genvar gu;
generate for (gu = 0; gu < UNITS; gu = gu + 1) begin : g_unit
	reg        mounted = 1'b0;
	reg        ro      = 1'b0;
	reg [31:0] blocks  = 32'd0;
	always @(posedge clk)
		if (img_mounted[gu]) begin
			mounted <= (img_size != 64'd0);
			ro      <= img_readonly;
			blocks  <= (img_size[63:41] != 23'd0) ? 32'hFFFF_FFFF : img_size[40:9];
		end
	assign u_mounted[gu]           = mounted;
	assign u_ro[gu]                = ro;
	assign u_blocks[gu*32 +: 32]   = blocks;

	if (CDROM[gu]) begin : g_msf
		reg [31:0] msf_rem = 32'd0;
		reg  [7:0] msf_m = 8'd0, msf_s = 8'd0, msf_f = 8'd0;
		reg  [1:0] msf_st = 2'd0;
		always @(posedge clk)
			if (img_mounted[gu]) begin
				msf_rem <= ((img_size[63:43] != 21'd0) ? 32'hFFFF_FF00 : img_size[42:11]) + 32'd150;
				msf_m   <= 8'd0;
				msf_s   <= 8'd0;
				msf_st  <= 2'd1;
			end
			else case (msf_st)
			2'd1:
				if (msf_rem >= 32'd4500) begin
					msf_rem <= msf_rem - 32'd4500;
					if (msf_m != 8'hFF) msf_m <= msf_m + 8'd1;
				end
				else msf_st <= 2'd2;
			2'd2:
				if (msf_rem >= 32'd75) begin
					msf_rem <= msf_rem - 32'd75;
					msf_s   <= msf_s + 8'd1;
				end
				else begin
					msf_f  <= msf_rem[7:0];
					msf_st <= 2'd0;
				end
			default: ;
			endcase
		assign u_msf[gu*24 +: 24] = {msf_m, msf_s, msf_f};
	end
	else begin : g_nomsf
		assign u_msf[gu*24 +: 24] = 24'd0;
	end
end endgenerate

// ---- bus outputs ----
reg        bsy_o, req_o, msg_o, cd_o, io_o;
reg  [7:0] data_o;
assign scsi_data_o = data_o;
assign {scsi_bsy_o, scsi_req_o, scsi_msg_o, scsi_cd_o, scsi_io_o} = {bsy_o, req_o, msg_o, cd_o, io_o};
assign {scsi_sel_o, scsi_atn_o, scsi_ack_o, scsi_rst_o} = 4'b0000;

// the target only watches SEL, BSY, ATN, ACK, RST and the data lines
wire unused_bus = &{1'b0, scsi_req_i, scsi_msg_i, scsi_cd_i, scsi_io_i};

// ---- state ----
reg  [4:0] st, ret;
reg [UW-1:0] cur;                         // the connected unit
reg  [3:0] cnt;
reg  [7:0] rxd;
reg  [7:0] cdb [0:9];
reg  [4:0] cpos;
reg        ident;
reg  [2:0] ident_lun;
reg  [7:0] status;
reg  [3:0] sense_key [0:UNITS-1];         // current sense, per unit
reg  [7:0] sense_asc [0:UNITS-1];
reg  [3:0] so_key;                        // what REQUEST SENSE is sending
reg  [7:0] so_asc;
reg  [2:0] kind;
reg        inq_bad;                       // INQUIRY for a LUN we do not have
reg        ms_dbd, ms_p3, ms_p4, ms_chg;
reg  [7:0] ms_base, ms_total;
reg [15:0] xlen, pos;
reg [31:0] lba;
reg [31:0] req_lba;                       // sd_lba, the same on every slot
reg  [5:0] req_cnt;                       // sd_blk_cnt, the same on every slot
reg [18:0] nblk;                          // 512-byte host blocks left
reg        disk_xfer;                     // DATA OUT goes to the disk (else dropped)
reg        ack_seen;
reg  [UNITS-1:0] ua    = {UNITS{1'b0}};   // CD-ROM: unit attention after a mount
reg  [UNITS-1:0] blk2k = {UNITS{1'b0}};   // CD-ROM: logical blocks are 2048 bytes
reg  [7:0] msel_bdl;                      // MODE SELECT: block descriptor length
reg [23:0] msel_bl;                       // MODE SELECT: block length

assign sd_lba     = {UNITS{req_lba}};
assign sd_blk_cnt = {UNITS{req_cnt}};

// ---- the connected unit ----
wire        is_cd   = CDROM[cur];
wire        mounted = u_mounted[cur];
wire        ro      = u_ro[cur];
wire [31:0] blocks  = u_blocks[cur*32 +: 32];
wire [23:0] msf     = u_msf[cur*24 +: 24];
wire        ack     = sd_ack[cur];
wire [3:0]  cur_key = sense_key[cur];
wire [7:0]  cur_asc = sense_asc[cur];
wire        sd_busy = |{sd_rd, sd_wr, sd_ack};    // a request outstanding on any unit

// blocks in the next HPS request, and its bytes in the buffer
localparam [18:0] MAXB19 = MAXB;
wire  [5:0] chunk   = is_cd ? 6'd1 : (nblk >= MAXB19) ? MAXB19[5:0] : nblk[5:0];
wire [15:0] chunk_b = {1'b0, chunk, 9'd0};
wire [18:0] chunk19 = {13'd0, chunk};

// selection: the lowest of our ID bits on the bus
wire        sel_hit = (scsi_data_i & IDS) != 8'h00;
reg [UW-1:0] sel_unit;
integer      si;
always @(*) begin
	sel_unit = {UW{1'b0}};
	for (si = UNITS - 1; si >= 0; si = si - 1)
		if (scsi_data_i[si]) sel_unit = si[UW-1:0];
end

// ---- CDB decode ----
wire [7:0] op       = cdb[0];
wire [2:0] lun      = ident ? ident_lun : cdb[1][7:5];
wire       bad_lun  = (lun != 3'd0);
wire       is_rw6   = (op == 8'h08) || (op == 8'h0A);
wire       is_rw10  = (op == 8'h28) || (op == 8'h2A);
wire       is_write = (op == 8'h0A) || (op == 8'h2A);
wire [31:0] c_lba   = is_rw6 ? {11'd0, cdb[1][4:0], cdb[2], cdb[3]}
                             : {cdb[2], cdb[3], cdb[4], cdb[5]};
wire [16:0] c_n     = is_rw6 ? ((cdb[4] == 8'd0) ? 17'd256 : {9'd0, cdb[4]})
                             : {1'b0, cdb[7], cdb[8]};
wire       big      = is_cd && blk2k[cur];
wire [31:0] cblocks = big ? {2'b00, blocks[31:2]} : blocks;     // in logical blocks
wire       c_range  = ({1'b0, c_lba} + {16'd0, c_n}) > {1'b0, cblocks};
wire [31:0] h_lba   = big ? {c_lba[29:0], 2'b00} : c_lba;       // in 512-byte host blocks
wire [18:0] h_n     = big ? {c_n, 2'b00} : {2'b00, c_n};
wire [5:0] ms_page  = cdb[2][5:0];
wire       ms_want3 = !is_cd && ((ms_page == 6'h03) || (ms_page == 6'h3F));
wire       ms_want4 = !is_cd && ((ms_page == 6'h04) || (ms_page == 6'h3F));
wire [15:0] alloc10 = {cdb[7], cdb[8]};
wire       toc_msf  = cdb[1][1];
wire       toc_lo   = (cdb[6] == 8'hAA);                       // lead-out only
wire       toc_bad  = (cdb[6] > 8'd1) && !toc_lo;
wire [7:0] ms_b     = cdb[1][3] ? 8'd4 : 8'd12;
wire [7:0] ms_t     = ms_b + (ms_want3 ? 8'd24 : 8'd0) + (ms_want4 ? 8'd24 : 8'd0);

function [4:0] cdb_len(input [2:0] grp);
	case (grp)
	3'd1, 3'd2: cdb_len = 5'd10;
	3'd4:       cdb_len = 5'd16;
	3'd5:       cdb_len = 5'd12;
	default:    cdb_len = 5'd6;
	endcase
endfunction

function [15:0] min16(input [15:0] a, input [15:0] b);
	min16 = (a < b) ? a : b;
endfunction

function known_op(input [7:0] o, input cd);
	case (o)
	8'h00, 8'h01, 8'h03, 8'h08, 8'h0A, 8'h0B, 8'h12, 8'h15, 8'h16, 8'h17,
	8'h1A, 8'h1B, 8'h1D, 8'h1E, 8'h25, 8'h28, 8'h2A, 8'h2B, 8'h2F, 8'h35:
		known_op = 1'b1;
	8'h04:                                  // FORMAT UNIT: disk only
		known_op = !cd;
	8'h42, 8'h43, 8'h44:                    // READ SUB-CHANNEL / TOC / HEADER: CD only
		known_op = cd;
	default: known_op = 1'b0;
	endcase
endfunction

// ---- synthesized data-in bytes ----
wire [31:0] last_lba = cblocks - 32'd1;
wire [23:0] nb24     = (cblocks[31:24] != 8'd0) ? 24'hFFFFFF : cblocks[23:0];
wire  [7:0] blen_hi  = big ? 8'h08 : 8'h02;                    // block length bits 15:8
wire  [3:0] tdsc     = pos[3:0] - 4'd4;                           // TOC: descriptor byte
wire        t_lo     = toc_lo || tdsc[3];                       // the lead-out descriptor
wire [31:0] lo_addr  = (toc_msf && is_cd) ? {8'd0, msf} : cblocks;
wire [23:0] cyls     = {1'b0, blocks[31:9]};
wire [223:0] inq_str = is_cd ? INQ_CD : INQ_DISK;
reg  [7:0]  syn;
reg  [7:0]  rel;
reg  [4:0]  rel4;
always @(*) begin
	syn  = 8'h00;
	rel  = pos[7:0] - ms_base;
	rel4 = rel[4:0] - (ms_p3 ? 5'd24 : 5'd0);
	case (kind)
	K_INQ:
		case (pos[5:0])
		6'd0: syn = inq_bad ? 8'h7F : is_cd ? 8'h05 : 8'h00;   // CD-ROM / direct access
		6'd1: syn = is_cd ? 8'h80 : 8'h00;     // RMB
		6'd2: syn = 8'h02;                     // SCSI-2
		6'd3: syn = 8'h02;                     // response format
		6'd4: syn = 8'd31;                     // additional length
		default:
			if (pos[5:0] >= 6'd8 && pos[5:0] < 6'd36)
				syn = inq_str[(8'd35 - {2'd0, pos[5:0]}) * 8 +: 8];
		endcase
	K_SENSE:
		case (pos[4:0])
		5'd0:  syn = 8'h70;                    // current error
		5'd2:  syn = {4'h0, so_key};
		5'd7:  syn = 8'd10;                    // additional length
		5'd12: syn = so_asc;
		default: ;
		endcase
	K_CAP:
		case (pos[2:0])
		3'd0: syn = last_lba[31:24];
		3'd1: syn = last_lba[23:16];
		3'd2: syn = last_lba[15:8];
		3'd3: syn = last_lba[7:0];
		3'd6: syn = blen_hi;                   // 512 or 2048
		default: ;
		endcase
	K_TOC:                                     // format 0
		if (pos[4:0] < 5'd4)
			case (pos[1:0])
			2'd1: syn = toc_lo ? 8'd10 : 8'd18;  // TOC data length
			2'd2: syn = 8'd1;                    // first track
			2'd3: syn = 8'd1;                    // last track
			default: ;
			endcase
		else
			case (tdsc[2:0])
			3'd1: syn = 8'h14;                   // ADR 1, data track
			3'd2: syn = t_lo ? 8'hAA : 8'd1;
			3'd4: syn = t_lo ? lo_addr[31:24] : 8'h00;
			3'd5: syn = t_lo ? lo_addr[23:16] : 8'h00;
			3'd6: syn = t_lo ? lo_addr[15:8]  : (toc_msf ? 8'd2 : 8'h00);   // track 1 at 00:02:00
			3'd7: syn = t_lo ? lo_addr[7:0]   : 8'h00;
			default: ;
			endcase
	K_SUBCH:
		if (pos[1:0] == 2'd1) syn = 8'h15;     // no current audio status
	K_HDR:
		case (pos[2:0])
		3'd0: syn = 8'h01;                     // mode 1
		3'd4: syn = cdb[2];
		3'd5: syn = cdb[3];
		3'd6: syn = cdb[4];
		3'd7: syn = cdb[5];
		default: ;
		endcase
	K_MSENSE:
		if (pos[7:0] < 8'd4)
			case (pos[1:0])
			2'd0: syn = ms_total - 8'd1;         // mode data length
			2'd2: syn = (ro || is_cd) ? 8'h80 : 8'h00;   // WP
			2'd3: syn = ms_dbd ? 8'd0 : 8'd8;    // block descriptor length
			default: ;
			endcase
		else if (pos[7:0] < ms_base)             // block descriptor
			case (pos[3:0])
			4'd5:  syn = nb24[23:16];
			4'd6:  syn = nb24[15:8];
			4'd7:  syn = nb24[7:0];
			4'd10: syn = blen_hi;                // 512 or 2048
			default: ;
			endcase
		else if (ms_p3 && rel < 8'd24) begin    // format device page
			case (rel[4:0])
			5'd0:  syn = 8'h03;
			5'd1:  syn = 8'h16;
			5'd3:  syn = ms_chg ? 8'h00 : HEADS;   // tracks per zone
			5'd11: syn = ms_chg ? 8'h00 : SPT;     // sectors per track
			5'd12: syn = ms_chg ? 8'h00 : 8'h02;   // bytes per sector
			5'd15: syn = ms_chg ? 8'h00 : 8'h01;   // interleave
			default: ;
			endcase
		end
		else if (ms_p4) begin                   // rigid disk geometry page
			case (rel4)
			5'd0:  syn = 8'h04;
			5'd1:  syn = 8'h16;
			5'd2:  syn = ms_chg ? 8'h00 : cyls[23:16];
			5'd3:  syn = ms_chg ? 8'h00 : cyls[15:8];
			5'd4:  syn = ms_chg ? 8'h00 : cyls[7:0];
			5'd5:  syn = ms_chg ? 8'h00 : HEADS;
			5'd20: syn = ms_chg ? 8'h00 : 8'h0E;   // 3600 rpm
			5'd21: syn = ms_chg ? 8'h00 : 8'h10;
			default: ;
			endcase
		end
	default: ;
	endcase
end

// ---- block buffer, shared: even / odd byte halves, one write and one
// read port each; word address {block in the request, word in the block} ----
localparam BW = (MAXB > 16) ? 13 : (MAXB > 8) ? 12 : (MAXB > 4) ? 11 : (MAXB > 2) ? 10 : (MAXB > 1) ? 9 : 8;
reg  [7:0] ram_e [0:MAXB*256-1];
reg  [7:0] ram_o [0:MAXB*256-1];
reg  [7:0] q_e, q_o;
wire       host_we = ack && sd_buff_wr && (st == S_RD_WAIT);
wire       scsi_we = (st == S_DOUT_B) && disk_xfer;
wire [BW-1:0] waddr = host_we ? sd_buff_addr[BW-1:0] : pos[BW:1];
wire       we_e    = host_we || (scsi_we && !pos[0]);
wire       we_o    = host_we || (scsi_we &&  pos[0]);
wire [7:0] wd_e    = host_we ? sd_buff_dout[7:0]  : rxd;
wire [7:0] wd_o    = host_we ? sd_buff_dout[15:8] : rxd;
wire [BW-1:0] raddr = ack ? sd_buff_addr[BW-1:0] : pos[BW:1];
always @(posedge clk) begin
	if (we_e) ram_e[waddr] <= wd_e;
	if (we_o) ram_o[waddr] <= wd_o;
	q_e <= ram_e[raddr];
	q_o <= ram_o[raddr];
end
assign sd_buff_din = {UNITS{q_o, q_e}};

// ---- target state machine ----
integer ui;

task automatic set_phase(input [2:0] p);    // {MSG, C/D, I/O}
	{msg_o, cd_o, io_o} <= p;
endtask

task automatic check(input [3:0] key, input [7:0] asc);
	status         <= 8'h02;
	sense_key[cur] <= key;
	sense_asc[cur] <= asc;
endtask

always @(posedge clk) begin
	if (reset || scsi_rst_i) begin
		bsy_o <= 1'b0; req_o <= 1'b0; data_o <= 8'h00;
		{msg_o, cd_o, io_o} <= 3'b000;
		st <= S_IDLE; ret <= S_IDLE;
		ident <= 1'b0;
		if (reset) begin
			sd_rd <= {UNITS{1'b0}}; sd_wr <= {UNITS{1'b0}}; req_lba <= 32'd0; req_cnt <= 6'd0;
			for (ui = 0; ui < UNITS; ui = ui + 1) begin
				sense_key[ui] <= SK_NONE; sense_asc[ui] <= ASC_NONE;
			end
			blk2k <= {UNITS{1'b0}};
		end
	end
	else begin
		case (st)
		S_IDLE:
			if (scsi_sel_i && !scsi_bsy_i && sel_hit) begin
				cnt <= 4'd0;
				st  <= S_SETTLE;
			end

		S_SETTLE: begin                        // bus settle, then answer with BSY
			cnt <= cnt + 4'd1;
			if (cnt == 4'd15) begin
				if (scsi_sel_i && !scsi_bsy_i && sel_hit) begin
					bsy_o <= 1'b1;
					cur   <= sel_unit;
					st    <= S_WSEL0;
				end
				else st <= S_IDLE;
			end
		end

		S_WSEL0:
			if (!scsi_sel_i) begin
				ident <= 1'b0;
				cpos  <= 5'd0;
				if (scsi_atn_i) begin set_phase(3'b110); ret <= S_MSGO; end
				else            begin set_phase(3'b010); ret <= S_CMD;  end
				st <= S_RXB;
			end

		S_MSGO: begin
			if (rxd[7]) begin ident <= 1'b1; ident_lun <= rxd[2:0]; end
			if (scsi_atn_i) begin
				ret <= S_MSGO;
				st  <= S_RXB;
			end
			else begin
				set_phase(3'b010);
				ret <= S_CMD;
				st  <= S_RXB;
			end
		end

		S_CMD: begin
			if (cpos < 5'd10) cdb[cpos[3:0]] <= rxd;
			cpos <= cpos + 5'd1;
			if (cpos + 5'd1 == cdb_len((cpos == 5'd0) ? rxd[7:5] : cdb[0][7:5])) st <= S_EXEC;
			else begin ret <= S_CMD; st <= S_RXB; end
		end

		S_EXEC: begin
			status    <= 8'h00;
			pos       <= 16'd0;
			disk_xfer <= 1'b0;
			lba       <= h_lba;
			nblk      <= h_n;
			inq_bad   <= bad_lun;
			ms_dbd    <= cdb[1][3];
			ms_p3     <= ms_want3;
			ms_p4     <= ms_want4;
			ms_chg    <= (cdb[2][7:6] == 2'b01);
			ms_base   <= ms_b;
			ms_total  <= ms_t;
			st        <= S_STAT;
			if (op != 8'h03) begin sense_key[cur] <= SK_NONE; sense_asc[cur] <= ASC_NONE; end

			if (op == 8'h12) begin                              // INQUIRY
				kind <= K_INQ;
				xlen <= min16({8'd0, cdb[4]}, 16'd36);
				set_phase(3'b001);
				st   <= S_DIN;
			end
			else if (op == 8'h03) begin                         // REQUEST SENSE
				kind <= K_SENSE;
				xlen <= (cdb[4] == 8'd0) ? 16'd4 : min16({8'd0, cdb[4]}, 16'd18);
				if (bad_lun) begin
					so_key <= SK_ILLEGAL; so_asc <= ASC_LUN;
				end
				else if (cur_key == SK_NONE && !mounted) begin
					so_key <= SK_NOT_READY; so_asc <= ASC_NO_MEDIUM;
				end
				else if (cur_key == SK_NONE && is_cd && ua[cur]) begin
					so_key  <= SK_UNIT_ATT; so_asc <= ASC_CHANGED;  // reported, so consumed
					ua[cur] <= 1'b0;
				end
				else begin
					so_key <= cur_key; so_asc <= cur_asc;
				end
				sense_key[cur] <= SK_NONE; sense_asc[cur] <= ASC_NONE;
				set_phase(3'b001);
				st <= S_DIN;
			end
			else if (is_cd && ua[cur] && mounted && !bad_lun) begin
				check(SK_UNIT_ATT, ASC_CHANGED);                // medium changed
				ua[cur] <= 1'b0;
			end
			else if (!known_op(op, is_cd))
				check(SK_ILLEGAL, ASC_BAD_OP);
			else if (bad_lun)
				check(SK_ILLEGAL, ASC_LUN);
			else if (!mounted)
				check(SK_NOT_READY, ASC_NO_MEDIUM);
			else if (is_rw6 || is_rw10) begin
				if (is_write && (ro || is_cd))
					check(SK_PROTECT, ASC_WPROT);
				else if (c_range)
					check(SK_ILLEGAL, ASC_LBA);
				else if (c_n != 17'd0) begin             // h_lba / h_n latched above
					disk_xfer <= 1'b1;
					if (is_write) begin set_phase(3'b000); st <= S_DOUT; end
					else          begin set_phase(3'b001); st <= S_RD_REQ; end
				end
			end
			else case (op)
			8'h25: begin                                        // READ CAPACITY
				kind <= K_CAP;
				xlen <= 16'd8;
				set_phase(3'b001);
				st   <= S_DIN;
			end
			8'h1A: begin                                        // MODE SENSE(6)
				kind <= K_MSENSE;
				xlen <= min16({8'd0, cdb[4]}, {8'd0, ms_t});
				set_phase(3'b001);
				st   <= S_DIN;
			end
			8'h15: begin                                        // MODE SELECT(6)
				xlen <= {8'd0, cdb[4]};
				set_phase(3'b000);
				st   <= S_DOUT;
			end
			8'h43:                                              // READ TOC (CD)
				if (toc_bad) check(SK_ILLEGAL, ASC_BAD_CDB);
				else begin
					kind <= K_TOC;
					xlen <= min16(alloc10, toc_lo ? 16'd12 : 16'd20);
					set_phase(3'b001);
					st   <= S_DIN;
				end
			8'h42: begin                                        // READ SUB-CHANNEL (CD)
				kind <= K_SUBCH;
				xlen <= min16(alloc10, 16'd4);
				set_phase(3'b001);
				st   <= S_DIN;
			end
			8'h44:                                              // READ HEADER (CD)
				if (toc_msf) check(SK_ILLEGAL, ASC_BAD_CDB);
				else begin
					kind <= K_HDR;
					xlen <= min16(alloc10, 16'd8);
					set_phase(3'b001);
					st   <= S_DIN;
				end
			8'h1D: begin                                        // SEND DIAGNOSTIC
				xlen <= {cdb[3], cdb[4]};
				set_phase(3'b000);
				st   <= S_DOUT;
			end
			default: ;                                          // GOOD, no data
			endcase
		end

		// ---- DATA IN from the synthesizer ----
		S_DIN:
			if (pos == xlen) st <= S_STAT;
			else begin
				data_o <= syn;
				pos    <= pos + 16'd1;
				ret    <= S_DIN;
				st     <= S_TXB;
			end

		// ---- DATA IN from the disk, `chunk` blocks per request ----
		S_RD_REQ:
			if (!sd_busy) begin
				req_lba    <= lba;
				req_cnt    <= chunk - 6'd1;
				sd_rd[cur] <= 1'b1;
				ack_seen   <= 1'b0;
				st         <= S_RD_WAIT;
			end

		S_RD_WAIT: begin
			if (ack) ack_seen <= 1'b1;
			if (ack_seen && !ack) begin
				pos <= 16'd0;
				st  <= S_RD_SEND;
			end
		end

		S_RD_SEND:                             // raddr = pos[BW:1] this cycle
			if (pos == chunk_b) begin
				lba  <= lba + {26'd0, chunk};
				nblk <= nblk - chunk19;
				st   <= (nblk == chunk19) ? S_STAT : S_RD_REQ;
			end
			else st <= S_RD_FETCH;

		S_RD_FETCH: begin
			data_o <= pos[0] ? q_o : q_e;
			pos    <= pos + 16'd1;
			ret    <= S_RD_SEND;
			st     <= S_TXB;
		end

		// ---- DATA OUT: to the buffer (disk) or dropped ----
		S_DOUT:
			if (pos == (disk_xfer ? chunk_b : xlen)) begin
				st <= disk_xfer ? S_WR_REQ : S_STAT;
				// CD-ROM MODE SELECT: the block descriptor sets the block length
				if (is_cd && !disk_xfer && op == 8'h15 && xlen >= 16'd12 && msel_bdl >= 8'd8) begin
					if (msel_bl == 24'd512)       blk2k[cur] <= 1'b0;
					else if (msel_bl == 24'd2048) blk2k[cur] <= 1'b1;
					else check(SK_ILLEGAL, ASC_BAD_PARAM);
				end
			end
			else begin
				ret <= S_DOUT_B;
				st  <= S_RXB;
			end

		S_DOUT_B: begin                        // buffer write happens here
			if (pos == 16'd3) msel_bdl <= rxd;
			if (pos >= 16'd9 && pos <= 16'd11) msel_bl <= {msel_bl[15:0], rxd};
			pos <= pos + 16'd1;
			st  <= S_DOUT;
		end

		S_WR_REQ:
			if (!sd_busy) begin
				req_lba    <= lba;
				req_cnt    <= chunk - 6'd1;
				sd_wr[cur] <= 1'b1;
				ack_seen   <= 1'b0;
				st         <= S_WR_WAIT;
			end

		S_WR_WAIT: begin
			if (ack) ack_seen <= 1'b1;
			if (ack_seen && !ack) begin
				lba  <= lba + {26'd0, chunk};
				nblk <= nblk - chunk19;
				pos  <= 16'd0;
				st   <= (nblk == chunk19) ? S_STAT : S_DOUT;
			end
		end

		// ---- STATUS, MESSAGE IN, BUS FREE ----
		S_STAT: begin
			set_phase(3'b011);
			data_o <= status;
			ret    <= S_MSGI;
			st     <= S_TXB;
		end

		S_MSGI: begin
			set_phase(3'b111);
			data_o <= 8'h00;                   // COMMAND COMPLETE
			ret    <= S_FREE;
			st     <= S_TXB;
		end

		S_FREE: begin
			bsy_o  <= 1'b0;
			set_phase(3'b000);
			data_o <= 8'h00;
			st     <= S_IDLE;
		end

		// ---- one byte to the initiator (data_o already set) ----
		S_TXB: begin
			req_o <= 1'b1;
			if (scsi_ack_i) begin
				req_o  <= 1'b0;
				data_o <= 8'h00;
				st     <= S_TXW;
			end
		end
		S_TXW:
			if (!scsi_ack_i) st <= ret;

		// ---- one byte from the initiator into rxd ----
		S_RXB: begin
			req_o <= 1'b1;
			if (scsi_ack_i) begin
				rxd   <= scsi_data_i;
				req_o <= 1'b0;
				st    <= S_RXW;
			end
		end
		S_RXW:
			if (!scsi_ack_i) st <= ret;

		default: st <= S_IDLE;
		endcase
	end

	for (ui = 0; ui < UNITS; ui = ui + 1) begin
		// a (re)mount: CD-ROM unit attention, block length back to 512
		if (img_mounted[ui]) begin
			ua[ui]    <= CDROM[ui] && (img_size != 64'd0);
			blk2k[ui] <= 1'b0;
		end
		// a request is taken when the HPS acknowledges it (also across a bus reset)
		if (!reset && sd_ack[ui]) begin
			sd_rd[ui] <= 1'b0;
			sd_wr[ui] <= 1'b0;
		end
	end
end

endmodule
