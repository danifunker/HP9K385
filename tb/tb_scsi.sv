//============================================================================
//  tb_scsi — mb87030 SPC (initiator, ID 7) + one scsi_target serving four
//  units (IDs 0-3) on one wired-OR bus, each unit with its own hps_io-timed
//  block-device model on a shared sd_buff_* bus muxed by sd_ack the way
//  hps_io does it.
//    ID 0  disk, 64-block image (mounted at the start)
//    ID 1  disk, 16-block image (mounted part-way through, once read-only)
//    ID 2  CD-ROM (CDROM bit 2) with an 8-sector (2048-byte) image, mounted
//          part-way through
//    ID 3  disk, never mounted
//    ID 5  absent (selection time-out)
//
//  A behavioural "CPU" drives the SPC registers the way NetBSD's spc driver
//  does (select with ATN + IDENTIFY, phase-driven program transfers, DMA
//  transfers through dreq / dack, MESSAGE IN with ACK held, bus-free
//  interrupt), and checks INTS, SSTS, PSNS, status and message bytes.  The
//  last part alternates commands between the units and checks that the
//  image, sense, unit attention and block length stay with their unit.
//
//  Build:  verilator --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_scsi
//          tb/tb_scsi.sv rtl/scsi/mb87030.sv rtl/scsi/scsi_target.sv
//============================================================================

`timescale 1ns/1ps

module tb_scsi;

localparam NBLK = 64;

// SPC registers
localparam [3:0] BDID = 0, SCTL = 1, SCMD = 2, TMOD = 3, INTS = 4, PSNS = 5, SSTS = 6,
                 SERR = 7, PCTL = 8, MBC = 9, DREG = 10, TEMP = 11, TCH = 12, TCM = 13,
                 TCL = 14, EXBF = 15;

reg clk = 1'b0;
always #15 clk = ~clk;                      // ~33 MHz
reg reset = 1'b1;

integer errors = 0;
task automatic chk(input bit ok, input string what);
	if (!ok) begin
		errors++;
		$display("FAIL @%0t: %s", $time, what);
	end
endtask

//----------------------------------------------------------------------------
// the bus: [0] I/O [1] C/D [2] MSG [3] BSY [4] SEL [5] REQ [6] ACK [7] ATN [8] RST
//----------------------------------------------------------------------------
wire [8:0] c_spc, c_t;
wire [7:0] d_spc, d_t;
wire [8:0] bc = c_spc | c_t;
wire [7:0] bd = d_spc | d_t;

// SPC host side
reg        cs = 0, we = 0;
reg  [3:0] rs = 0;
reg  [7:0] din = 0;
wire [7:0] dout;
wire       irq, dreq;
reg        dack_rd = 0, dack_wr = 0;
wire [7:0] dack_dout;
reg  [7:0] dack_din = 0;
reg        ext_ctrl_wr = 0;
reg  [8:0] ext_ctrl = 0;

mb87030 spc
(
	.clk(clk), .reset(reset),
	.cs(cs), .we(we), .rs(rs), .din(din), .dout(dout), .irq(irq),
	.dreq(dreq), .dack_rd(dack_rd), .dack_dout(dack_dout), .dack_wr(dack_wr), .dack_din(dack_din),
	.ext_ctrl_wr(ext_ctrl_wr), .ext_ctrl(ext_ctrl),
	.scsi_data_o(d_spc),
	.scsi_bsy_o(c_spc[3]), .scsi_sel_o(c_spc[4]), .scsi_atn_o(c_spc[7]), .scsi_ack_o(c_spc[6]),
	.scsi_rst_o(c_spc[8]), .scsi_req_o(c_spc[5]), .scsi_msg_o(c_spc[2]), .scsi_cd_o(c_spc[1]),
	.scsi_io_o(c_spc[0]),
	.scsi_data_i(bd),
	.scsi_bsy_i(bc[3]), .scsi_sel_i(bc[4]), .scsi_atn_i(bc[7]), .scsi_ack_i(bc[6]), .scsi_rst_i(bc[8]),
	.scsi_req_i(bc[5]), .scsi_msg_i(bc[2]), .scsi_cd_i(bc[1]), .scsi_io_i(bc[0])
);

// the targets: IDs 0-3, ID 2 a CD-ROM
reg   [3:0] img_mounted = 0;
reg  [63:0] img_size = 0;                   // shared, as in hps_io
reg         img_ro = 0;
wire [127:0] t_lba;
wire  [3:0] t_rd, t_wr, t_ack;
wire  [7:0] t_baddr;
wire [15:0] t_bdout;
wire        t_bwr;
wire [63:0] t_bdin;

scsi_target #(.UNITS(4), .CDROM(4'b0100)) tgt
(
	.clk(clk), .reset(reset),
	.scsi_data_o(d_t),
	.scsi_bsy_o(c_t[3]), .scsi_sel_o(c_t[4]), .scsi_atn_o(c_t[7]), .scsi_ack_o(c_t[6]),
	.scsi_rst_o(c_t[8]), .scsi_req_o(c_t[5]), .scsi_msg_o(c_t[2]), .scsi_cd_o(c_t[1]),
	.scsi_io_o(c_t[0]),
	.scsi_data_i(bd),
	.scsi_bsy_i(bc[3]), .scsi_sel_i(bc[4]), .scsi_atn_i(bc[7]), .scsi_ack_i(bc[6]), .scsi_rst_i(bc[8]),
	.scsi_req_i(bc[5]), .scsi_msg_i(bc[2]), .scsi_cd_i(bc[1]), .scsi_io_i(bc[0]),
	.img_mounted(img_mounted), .img_size(img_size), .img_readonly(img_ro),
	.sd_lba(t_lba), .sd_rd(t_rd), .sd_wr(t_wr), .sd_ack(t_ack),
	.sd_buff_addr(t_baddr), .sd_buff_dout(t_bdout), .sd_buff_wr(t_bwr),
	.sd_buff_din(t_bdin)
);

task automatic mount(input int u, input longint size, input bit ro);
	@(negedge clk); img_size = size; img_ro = ro; img_mounted[u] = 1;
	@(negedge clk); img_mounted = 0;
endtask

// disk 0: the model below
wire [31:0] sd_lba0 = t_lba[31:0];
wire        sd_rd0 = t_rd[0], sd_wr0 = t_wr[0];
reg         sd_ack0 = 0;
reg   [7:0] sd_buff_addr0 = 0;
reg  [15:0] sd_buff_dout0 = 0;
reg         sd_buff_wr0 = 0;
wire [15:0] sd_buff_din0 = t_bdin[15:0];

// disk 1
localparam D1_BLK = 16;
wire        d1_ack, d1_bwr;
wire  [7:0] d1_baddr;
wire [15:0] d1_bdout;

tb_blkdev #(.NBLK(D1_BLK)) d1_dev
(
	.clk(clk), .reset(reset),
	.sd_lba(t_lba[63:32]), .sd_rd(t_rd[1]), .sd_wr(t_wr[1]), .sd_ack(d1_ack),
	.sd_buff_addr(d1_baddr), .sd_buff_dout(d1_bdout), .sd_buff_wr(d1_bwr), .sd_buff_din(t_bdin[31:16])
);

// ID 2: CD-ROM
localparam CD_SECT = 8;                     // 2048-byte sectors
wire        cd_ack, cd_bwr;
wire  [7:0] cd_baddr;
wire [15:0] cd_bdout;

tb_blkdev #(.NBLK(CD_SECT * 4)) cd_dev
(
	.clk(clk), .reset(reset),
	.sd_lba(t_lba[95:64]), .sd_rd(t_rd[2]), .sd_wr(t_wr[2]), .sd_ack(cd_ack),
	.sd_buff_addr(cd_baddr), .sd_buff_dout(cd_bdout), .sd_buff_wr(cd_bwr), .sd_buff_din(t_bdin[47:32])
);

// hps_io: one sd_buff bus, sd_ack per slot
assign t_ack   = {1'b0, cd_ack, d1_ack, sd_ack0};
assign t_baddr = sd_ack0 ? sd_buff_addr0 : d1_ack ? d1_baddr : cd_ack ? cd_baddr : 8'd0;
assign t_bdout = sd_ack0 ? sd_buff_dout0 : d1_ack ? d1_bdout : cd_ack ? cd_bdout : 16'd0;
assign t_bwr   = sd_ack0 ? sd_buff_wr0   : d1_ack ? d1_bwr   : cd_ack ? cd_bwr   : 1'b0;

always @(posedge clk)
	if (!reset) begin
		if (t_rd[3] || t_wr[3]) chk(0, "ID 3 (no image) made a block request");
		if (t_wr[2]) chk(0, "CD-ROM made a block write");
		if ($countones(t_rd | t_wr | t_ack) > 1)
			chk(0, $sformatf("more than one block request at once: rd %b wr %b ack %b", t_rd, t_wr, t_ack));
		if ((d_spc & d_t) != 0)
			chk(0, $sformatf("data bus contention spc=%02x tgt=%02x", d_spc, d_t));
	end

//----------------------------------------------------------------------------
// block device for disk 0 (hps_io WIDE=1 timing, little-endian words)
//----------------------------------------------------------------------------
reg [7:0] img [0:NBLK*512-1];
integer   blk_reads = 0, blk_writes = 0;
integer   slow0 = 0;                        // extra clocks before sd_ack

initial begin
	forever begin
		@(negedge clk);
		if (sd_rd0 || sd_wr0) begin
			bit isrd;
			int l;
			isrd = sd_rd0;
			l    = sd_lba0;
			chk(!(sd_rd0 && sd_wr0), "sd_rd and sd_wr together");
			chk(l < NBLK, $sformatf("sd_lba %0d out of range", l));
			repeat ($urandom_range(5, 60) + slow0) begin
				@(negedge clk);
				chk(isrd ? sd_rd0 : sd_wr0, "block request dropped before sd_ack");
				chk(sd_lba0 == l, "sd_lba changed while requesting");
			end
			sd_ack0       = 1;
			sd_buff_addr0 = 0;
			repeat (2) @(negedge clk);
			chk(!sd_rd0 && !sd_wr0, "block request still up after sd_ack");
			for (int w = 0; w < 256; w++) begin
				sd_buff_addr0 = w;
				if (isrd) begin
					sd_buff_dout0 = {img[l*512 + 2*w + 1], img[l*512 + 2*w]};
					@(negedge clk); sd_buff_wr0 = 1;
					@(negedge clk); sd_buff_wr0 = 0;
					@(negedge clk);
				end
				else begin
					repeat ($urandom_range(2, 4)) @(negedge clk);
					{img[l*512 + 2*w + 1], img[l*512 + 2*w]} = sd_buff_din0;
				end
			end
			repeat (2) @(negedge clk);
			sd_ack0 = 0;
			if (isrd) blk_reads++; else blk_writes++;
		end
	end
end

//----------------------------------------------------------------------------
// DMA engine: one byte per dack; it samples dreq in the cycle of its own
// acknowledge and may commit to the next byte right away (as hp98620 does)
//----------------------------------------------------------------------------
reg [7:0] dbuf [0:8191];                    // data in
reg [7:0] obuf [0:8191];                    // data out
reg [7:0] sbuf [0:63];                      // small program-transfer reads
integer   dma_left = 0, dma_idx = 0;
bit       dma_in = 0;

initial begin
	bit commit;
	commit = 0;
	forever begin
		if (!commit) begin
			@(negedge clk); #1;
			commit = (dma_left > 0) && dreq;
		end
		if (commit) begin
			if (dma_in) begin
				dack_rd = 1; #1;
				dbuf[dma_idx] = dack_dout;
				dma_idx++; dma_left--;
				commit = dreq && (dma_left > 0) && ($urandom_range(0, 1) == 1);
				@(negedge clk); dack_rd = 0;
			end
			else begin
				repeat ($urandom_range(0, 2)) @(negedge clk);
				dack_din = obuf[dma_idx];
				dack_wr  = 1;
				dma_idx++; dma_left--;
				#1;
				commit = dreq && (dma_left > 0);
				@(negedge clk); dack_wr = 0;
			end
		end
	end
end

//----------------------------------------------------------------------------
// CPU
//----------------------------------------------------------------------------
task automatic wr(input [3:0] r, input [7:0] d);
	@(negedge clk); cs = 1; we = 1; rs = r; din = d;
	@(negedge clk); cs = 0; we = 0;
endtask

task automatic rd(input [3:0] r, output [7:0] d);
	@(negedge clk); cs = 1; we = 0; rs = r; #1; d = dout;
	@(negedge clk); cs = 0;
endtask

task automatic wr_tc(input int n);
	wr(TCH, n[23:16]); wr(TCM, n[15:8]); wr(TCL, n[7:0]);
endtask

task automatic wait_ints(output [7:0] v);
	int n;
	n = 0;
	do begin
		rd(INTS, v);
		n++;
	end while (v == 8'h00 && n < 2000000);
	chk(v != 8'h00, "timeout waiting for INTS");
	#1 chk(irq == 1'b1, "irq pin low with INTS set and SCTL IE");
endtask

task automatic clr_ints(input [7:0] v);
	wr(INTS, v);
	#1 chk(irq == 1'b0, $sformatf("irq still high after clearing INTS %02x", v));
endtask

task automatic wait_req(output [2:0] ph);
	reg [7:0] p;
	int n;
	n = 0;
	do begin
		rd(PSNS, p);
		n++;
	end while (!p[7] && n < 2000000);
	chk(p[7], "timeout waiting for REQ");
	chk(p[3], "REQ without BSY");
	ph = p[2:0];
endtask

// program transfer out of obuf (or the CDB), n bytes, phase ph
reg [7:0] cdbb [0:15];
task automatic prg_out(input [2:0] ph, input int n, input bit from_cdb);
	reg [7:0] s, v;
	wr(PCTL, {5'd0, ph});
	wr_tc(n);
	wr(SCMD, 8'h84);
	for (int i = 0; i < n; i++) begin
		do rd(SSTS, s); while (s[1]);   // FIFO full
		wr(DREG, from_cdb ? cdbb[i] : obuf[i]);
	end
	wait_ints(v);
	chk(v == 8'h10, $sformatf("program out phase %0d: INTS %02x, want 10", ph, v));
	clr_ints(v);
	rd(SSTS, s);
	chk(s[5:4] == 2'b00, $sformatf("SSTS %02x busy after transfer", s));
endtask

// program transfer in, up to max bytes, into dbuf (to_dbuf) or sbuf
task automatic prg_in(input [2:0] ph, input int max, input bit to_dbuf, output int got, output [7:0] v);
	reg [7:0] s, b;
	wr(PCTL, {(ph == 3'd7), 4'd0, ph});      // bus-free IE for MESSAGE IN
	wr_tc(max);
	wr(SCMD, 8'h84);
	got = 0;
	forever begin
		rd(SSTS, s);
		if (!s[0]) begin
			rd(DREG, b);
			if (to_dbuf) dbuf[got] = b; else sbuf[got] = b;
			got++;
		end
		else begin
			rd(INTS, v);
			if (v != 8'h00) break;
		end
	end
	// a phase change may leave bytes behind
	forever begin
		rd(SSTS, s);
		if (s[0]) break;
		rd(DREG, b);
		if (to_dbuf) dbuf[got] = b; else sbuf[got] = b;
		got++;
	end
	clr_ints(v);
endtask

task automatic dma_xfer(input bit in, input [2:0] ph, input int n);
	reg [7:0] v, s;
	dma_in = in; dma_idx = 0;
	wr(PCTL, {5'd0, ph});
	wr_tc(n);
	dma_left = n + 4;                        // the DMA count is generous: dreq must stop at TC
	wr(SCMD, 8'h80);
	wait_ints(v);
	chk(v == 8'h10, $sformatf("DMA phase %0d: INTS %02x, want 10", ph, v));
	chk(dma_left == 4, $sformatf("DMA moved %0d bytes, want %0d", n + 4 - dma_left, n));
	dma_left = 0;
	clr_ints(v);
	rd(SSTS, s);
	chk(s == 8'h85, $sformatf("SSTS %02x after DMA, want 85", s));
endtask

// selection: returns INTS
task automatic select(input int tgt, input bit atn, input bit arb, output [7:0] v);
	reg [7:0] s;
	wr(SCMD, atn ? 8'h60 : 8'h40);          // set / reset ATN
	wr(SCTL, arb ? 8'h11 : 8'h01);
	wr(PCTL, 8'h00);
	wr(TEMP, 8'h80 | (8'd1 << tgt));
	wr(TCH, 8'h00); wr(TCM, 8'h20); wr(TCL, 8'h03);  // ~2 ms
	wr(SCMD, 8'h20);
	rd(SSTS, s);
	chk(s[5], "SSTS busy not set during selection");
	wait_ints(v);
endtask

// one full command; data phases by DMA (use_dma) or program transfer
integer last_in;
// NetBSD's mb89352 driver (sys/dev/ic/mb89352.c) reads STATUS and MESSAGE
// IN by hand: with REQ up it reads the byte from TEMP *before* SET ACK, then
// SET ACK, waits for REQ to drop, RESET ACK.
bit nbsd_style = 0;
task automatic nbsd_in(output [7:0] b);
	reg [7:0] p;
	rd(TEMP, b);
	wr(SCMD, 8'hE0);                         // set ACK
	do rd(PSNS, p); while (p[7]);
	wr(SCMD, 8'hC0);                         // reset ACK
endtask

task automatic run_cmd(input int tgt, input bit atn, input bit arb, input int clen,
                       input bit use_dma, input int dlen, input bit manual_status,
                       output [7:0] stat);
	reg [7:0] v, s, p, m;
	reg [2:0] ph;
	int got, nph;
	bit done;
	select(tgt, atn, arb, v);
	chk(v == 8'h10, $sformatf("select %0d: INTS %02x, want 10", tgt, v));
	clr_ints(v);
	rd(SSTS, s);
	chk(s[7] && !s[5], $sformatf("select %0d: SSTS %02x", tgt, s));
	if (atn) begin
		wait_req(ph);
		rd(PSNS, p);
		chk(p == 8'hAE, $sformatf("MESSAGE OUT PSNS %02x, want AE", p));
		m = obuf[0];
		obuf[0] = 8'h80;                     // IDENTIFY, LUN 0
		prg_out(3'd6, 1, 0);
		obuf[0] = m;
	end
	last_in = 0;
	stat = 8'hFF;
	done = 0;
	nph  = 0;
	while (!done) begin
		nph++;
		if (nph > 16) begin
			chk(0, $sformatf("target %0d op %02x: no end of command after 16 phases", tgt, cdbb[0]));
			$display("FAILED: %0d errors", errors);
			$finish;
		end
		wait_req(ph);
		rd(PSNS, p);
		chk(!p[5], $sformatf("ATN still up after MESSAGE OUT (PSNS %02x)", p));
		case (ph)
		3'd2: prg_out(3'd2, clen, 1);
		3'd1: begin
			if (use_dma) begin dma_xfer(1, 3'd1, dlen); last_in = dlen; end
			else begin
				prg_in(3'd1, dlen, 1, got, v);
				last_in = got;
			end
		end
		3'd0: begin
			if (use_dma) dma_xfer(0, 3'd0, dlen);
			else prg_out(3'd0, dlen, 0);
		end
		3'd3: begin
			if (nbsd_style) nbsd_in(stat);
			else if (manual_status) begin
				// manual handshake: SET ACK latches the byte into TEMP
				wr(SCMD, 8'hE0);
				do rd(PSNS, p); while (p[7]);
				chk(p[6], "manual ACK not on the bus");
				rd(TEMP, stat);
				wr(SCMD, 8'hC0);
			end
			else begin
				prg_in(3'd3, 1, 0, got, v);
				chk(got == 1 && v == 8'h10, $sformatf("STATUS: %0d bytes, INTS %02x", got, v));
				stat = sbuf[0];
			end
		end
		3'd7: if (nbsd_style) begin
			nbsd_in(m);
			chk(m == 8'h00, $sformatf("NetBSD-style MESSAGE IN %02x, want 00", m));
			wait_ints(v);
			chk(v == 8'h20, $sformatf("NetBSD-style bus free: INTS %02x, want 20", v));
			clr_ints(v);
			wr(PCTL, 8'h00);
			done = 1;
		end
		else begin
			prg_in(3'd7, 1, 0, got, v);
			chk(got == 1 && v == 8'h10, $sformatf("MESSAGE IN: %0d bytes, INTS %02x", got, v));
			chk(sbuf[0] == 8'h00, $sformatf("MESSAGE IN %02x, want 00", sbuf[0]));
			rd(PSNS, p);
			chk(p[6] && !p[7], $sformatf("PSNS %02x: ACK not held on last MESSAGE IN byte", p));
			wr(SCMD, 8'hC0);                 // reset ACK -> target frees the bus
			wait_ints(v);
			chk(v == 8'h20, $sformatf("bus free: INTS %02x, want 20", v));
			clr_ints(v);
			rd(SSTS, s);
			chk(s[7:4] == 4'h0, $sformatf("SSTS %02x after disconnect", s));
			rd(PSNS, p);
			chk(p == 8'h00, $sformatf("PSNS %02x after disconnect", p));
			wr(PCTL, 8'h00);
			done = 1;
		end
		default: begin
			chk(0, $sformatf("unexpected phase %0d", ph));
			done = 1;
		end
		endcase
	end
endtask

task automatic set_cdb6(input [7:0] b0, b1, b2, b3, b4, b5);
	cdbb[0] = b0; cdbb[1] = b1; cdbb[2] = b2; cdbb[3] = b3; cdbb[4] = b4; cdbb[5] = b5;
endtask

task automatic set_cdb10(input [7:0] op, input [31:0] lba, input [15:0] n);
	cdbb[0] = op; cdbb[1] = 0; cdbb[2] = lba[31:24]; cdbb[3] = lba[23:16];
	cdbb[4] = lba[15:8]; cdbb[5] = lba[7:0]; cdbb[6] = 0; cdbb[7] = n[15:8]; cdbb[8] = n[7:0];
	cdbb[9] = 0;
endtask

task automatic sense_is(input int tgt, input [7:0] key, input [7:0] asc, input string what);
	reg [7:0] st;
	set_cdb6(8'h03, 0, 0, 0, 18, 0);
	run_cmd(tgt, 1, 1, 6, 0, 18, 0, st);
	chk(st == 8'h00 && last_in == 18, {what, ": REQUEST SENSE"});
	chk(dbuf[2] == key && dbuf[12] == asc,
	    $sformatf("%s: sense %02x/%02x, want %02x/%02x", what, dbuf[2], dbuf[12], key, asc));
endtask

task automatic cap_is(input int tgt, input int last, input int len, input string what);
	reg [7:0] st;
	set_cdb10(8'h25, 0, 0);
	run_cmd(tgt, 1, 1, 10, 0, 8, 0, st);
	chk(st == 8'h00 && last_in == 8, {what, ": READ CAPACITY status"});
	chk({dbuf[0], dbuf[1], dbuf[2], dbuf[3]} == last && {dbuf[4], dbuf[5], dbuf[6], dbuf[7]} == len,
	    $sformatf("%s: READ CAPACITY %0d / %0d, want %0d / %0d", what,
	              {dbuf[0], dbuf[1], dbuf[2], dbuf[3]}, {dbuf[4], dbuf[5], dbuf[6], dbuf[7]}, last, len));
endtask

// MODE SELECT(6): header + one block descriptor with the given block length
task automatic mode_select(input int tgt, input [23:0] blen, output [7:0] st);
	for (int i = 0; i < 12; i++) obuf[i] = 8'h00;
	obuf[3] = 8'd8;
	{obuf[9], obuf[10], obuf[11]} = blen;
	set_cdb6(8'h15, 8'h10, 0, 0, 12, 0);
	run_cmd(tgt, 1, 1, 6, 0, 12, 0, st);
endtask

task automatic read_toc_on(input int tgt, input bit msf, input [7:0] track, input [15:0] alloc, output [7:0] st);
	cdbb[0] = 8'h43; cdbb[1] = msf ? 8'h02 : 8'h00; cdbb[2] = 0; cdbb[3] = 0; cdbb[4] = 0; cdbb[5] = 0;
	cdbb[6] = track; cdbb[7] = alloc[15:8]; cdbb[8] = alloc[7:0]; cdbb[9] = 0;
	run_cmd(tgt, 1, 1, 10, 0, alloc, 0, st);
endtask

task automatic read_toc(input bit msf, input [7:0] track, input [15:0] alloc, output [7:0] st);
	read_toc_on(2, msf, track, alloc, st);
endtask

//----------------------------------------------------------------------------
// the test
//----------------------------------------------------------------------------
reg [7:0] v, s, p, st;
reg [7:0] cdgold [0:CD_SECT*2048-1];
reg [7:0] golden [0:NBLK*512-1];
reg [7:0] d1gold [0:D1_BLK*512-1];
int bad;

function automatic [7:0] gold_byte(input int tgt, input int a);
	case (tgt)
	0:       return golden[a];
	1:       return d1gold[a];
	default: return cdgold[a];
	endcase
endfunction

task automatic tur_is(input int tgt, input [7:0] want, input string what);
	reg [7:0] st;
	set_cdb6(8'h00, 0, 0, 0, 0, 0);
	run_cmd(tgt, 1, 1, 6, 0, 0, 0, st);
	chk(st == want, $sformatf("%s: TEST UNIT READY %02x, want %02x", what, st, want));
endtask

// INQUIRY: peripheral type, RMB and product name follow the unit
task automatic inq_is(input int tgt, input bit cd, input string what);
	reg [7:0] st;
	for (int i = 0; i < 36; i++) dbuf[i] = 8'hEE;
	set_cdb6(8'h12, 0, 0, 0, 36, 0);
	run_cmd(tgt, 1, 1, 6, 0, 36, 0, st);
	chk(st == 8'h00 && last_in == 36, {what, ": INQUIRY status"});
	chk(dbuf[0] == (cd ? 8'h05 : 8'h00) && dbuf[1] == (cd ? 8'h80 : 8'h00),
	    $sformatf("%s: INQUIRY type %02x rmb %02x", what, dbuf[0], dbuf[1]));
	chk({dbuf[21], dbuf[22], dbuf[23]} == (cd ? "CD-" : "DIS"),
	    $sformatf("%s: INQUIRY product %s", what, {dbuf[16], dbuf[17], dbuf[18], dbuf[19], dbuf[20], dbuf[21], dbuf[22], dbuf[23]}));
endtask

// READ(10) by DMA, n blocks of blen bytes, checked against the unit's image
task automatic read_is(input int tgt, input int lba, input int n, input int blen, input string what);
	reg [7:0] st;
	int nb;
	for (int i = 0; i < n * blen; i++) dbuf[i] = 8'hEE;
	set_cdb10(8'h28, lba, n);
	run_cmd(tgt, 1, 1, 10, 1, n * blen, 0, st);
	chk(st == 8'h00, $sformatf("%s: READ(10) status %02x", what, st));
	nb = 0;
	for (int i = 0; i < n * blen; i++) if (dbuf[i] != gold_byte(tgt, lba * blen + i)) nb++;
	chk(nb == 0, $sformatf("%s: READ(10) %0d bytes differ", what, nb));
endtask

task automatic msense_wp_is(input int tgt, input bit wp, input string what);
	reg [7:0] st;
	set_cdb6(8'h1A, 0, 8'h00, 0, 255, 0);
	run_cmd(tgt, 1, 1, 6, 0, 255, 0, st);
	chk(st == 8'h00 && last_in == 12 && dbuf[2][7] == wp,
	    $sformatf("%s: MODE SENSE %0d bytes, WP byte %02x", what, last_in, dbuf[2]));
endtask

initial begin
	for (int i = 0; i < NBLK*512; i++) begin
		img[i]    = 8'((i >> 9) * 37 + (i & 511) * 7 + (i >> 4));
		golden[i] = img[i];
	end

	repeat (5) @(negedge clk);
	reset = 0;
	repeat (5) @(negedge clk);

	// mount the image on disk 0
	mount(0, NBLK * 512, 0);

	// ---- register basics (NetBSD spc_init order) ----
	rd(SCTL, v); chk(v == 8'h80, $sformatf("SCTL after reset %02x, want 80", v));
	rd(SSTS, s); chk(s == 8'h05, $sformatf("SSTS after reset %02x, want 05", s));
	rd(INTS, v); chk(v == 8'h00, "INTS after reset");
	wr(SCTL, 8'hC0);
	wr(SCMD, 8'h00); wr(PCTL, 8'h00); wr(TEMP, 8'h00); wr_tc(0); wr(INTS, 8'h00);
	wr(SCTL, 8'h9A);
	wr(BDID, 8'h07);
	rd(BDID, v); chk(v == 8'h80, $sformatf("BDID read %02x, want 80", v));
	wr(SCTL, 8'h1A);
	wr(SCTL, 8'h11);
	rd(SCTL, v); chk(v == 8'h11, "SCTL readback");
	wr_tc(24'h123456);
	rd(TCH, v); chk(v == 8'h12, "TCH"); rd(TCM, v); chk(v == 8'h34, "TCM"); rd(TCL, v); chk(v == 8'h56, "TCL");
	rd(SSTS, s); chk(s == 8'h01, $sformatf("SSTS with TC != 0: %02x, want 01", s));
	wr_tc(0);
	// DREG through the FIFO
	for (int i = 0; i < 8; i++) wr(DREG, 8'hA0 + i);
	rd(SSTS, s); chk(s == 8'h06, $sformatf("SSTS with full FIFO %02x, want 06", s));
	for (int i = 0; i < 8; i++) begin
		rd(DREG, v); chk(v == 8'hA0 + i, $sformatf("FIFO byte %0d = %02x", i, v));
	end
	rd(SSTS, s); chk(s == 8'h05, $sformatf("SSTS with empty FIFO %02x, want 05", s));
	// card register 2 direct control
	@(negedge clk); ext_ctrl = 9'h00C; ext_ctrl_wr = 1;      // BSY | MSG
	@(negedge clk); ext_ctrl_wr = 0;
	rd(PSNS, p); chk(p == 8'h0C, $sformatf("PSNS after direct control %02x, want 0C", p));
	@(negedge clk); ext_ctrl = 9'h000; ext_ctrl_wr = 1;
	@(negedge clk); ext_ctrl_wr = 0;
	rd(PSNS, p); chk(p == 8'h00, "PSNS after direct control release");
	rd(INTS, v); chk(v == 8'h00, $sformatf("INTS %02x after direct control", v));

	// ---- ID 0: INQUIRY (program transfer, ATN + IDENTIFY, arbitration) ----
	set_cdb6(8'h12, 0, 0, 0, 36, 0);
	run_cmd(0, 1, 1, 6, 0, 36, 0, st);
	chk(st == 8'h00, $sformatf("INQUIRY status %02x", st));
	chk(last_in == 36, $sformatf("INQUIRY returned %0d bytes", last_in));
	chk(dbuf[0] == 8'h00 && dbuf[4] == 8'd31, "INQUIRY header");
	chk({dbuf[8], dbuf[9], dbuf[10], dbuf[11], dbuf[12], dbuf[13], dbuf[14], dbuf[15]} == "HP9K385 ",
	    "INQUIRY vendor");
	chk({dbuf[16], dbuf[17], dbuf[18], dbuf[19], dbuf[20], dbuf[21], dbuf[22], dbuf[23], dbuf[24]} == "SCSI DISK",
	    "INQUIRY product");
	$display("INQUIRY ok");

	// ---- TEST UNIT READY, status by manual SET/RESET ACK ----
	set_cdb6(8'h00, 0, 0, 0, 0, 0);
	run_cmd(0, 1, 1, 6, 0, 0, 1, st);
	chk(st == 8'h00, $sformatf("TEST UNIT READY status %02x", st));
	$display("TEST UNIT READY ok");

	// ---- NetBSD-style STATUS / MESSAGE IN (TEMP read before SET ACK) ----
	nbsd_style = 1;
	set_cdb6(8'h00, 0, 0, 0, 0, 0);
	run_cmd(0, 0, 1, 6, 0, 0, 0, st);
	chk(st == 8'h00, $sformatf("NetBSD-style TEST UNIT READY status %02x, want 00", st));
	set_cdb6(8'h12, 0, 0, 0, 36, 0);
	run_cmd(0, 0, 1, 6, 0, 36, 0, st);
	chk(st == 8'h00 && last_in == 36 && dbuf[0] == 8'h00,
	    $sformatf("NetBSD-style INQUIRY: status %02x, %0d bytes, type %02x", st, last_in, dbuf[0]));
	nbsd_style = 0;
	$display("NetBSD-style status/message ok");

	// ---- READ CAPACITY ----
	set_cdb10(8'h25, 0, 0);
	run_cmd(0, 1, 1, 10, 0, 8, 0, st);
	chk(st == 8'h00, "READ CAPACITY status");
	chk(last_in == 8, "READ CAPACITY length");
	chk({dbuf[0], dbuf[1], dbuf[2], dbuf[3]} == NBLK - 1, $sformatf("READ CAPACITY last LBA %02x%02x%02x%02x",
	    dbuf[0], dbuf[1], dbuf[2], dbuf[3]));
	chk({dbuf[4], dbuf[5], dbuf[6], dbuf[7]} == 512, "READ CAPACITY block length");
	$display("READ CAPACITY ok");

	// ---- READ(10), 4 blocks by DMA ----
	set_cdb10(8'h28, 5, 4);
	run_cmd(0, 1, 1, 10, 1, 2048, 0, st);
	chk(st == 8'h00, "READ(10) status");
	bad = 0;
	for (int i = 0; i < 2048; i++) if (dbuf[i] != golden[5*512 + i]) bad++;
	chk(bad == 0, $sformatf("READ(10): %0d bytes differ", bad));
	$display("READ(10) DMA ok (%0d block reads)", blk_reads);

	// ---- WRITE(10), 2 blocks by DMA, then read back ----
	for (int i = 0; i < 1024; i++) begin
		obuf[i] = 8'($urandom);
		golden[10*512 + i] = obuf[i];
	end
	set_cdb10(8'h2A, 10, 2);
	run_cmd(0, 1, 1, 10, 1, 1024, 0, st);
	chk(st == 8'h00, "WRITE(10) status");
	chk(blk_writes == 2, $sformatf("%0d block writes, want 2", blk_writes));
	bad = 0;
	for (int i = 0; i < NBLK*512; i++)
		if (img[i] != golden[i]) begin
			if (bad == 0) $display("  first difference at image byte %0d: %02x, want %02x", i, img[i], golden[i]);
			bad++;
		end
	chk(bad == 0, $sformatf("image after WRITE(10): %0d bytes differ", bad));
	for (int i = 0; i < 2048; i++) dbuf[i] = 8'h00;
	set_cdb10(8'h28, 9, 4);
	run_cmd(0, 1, 1, 10, 1, 2048, 0, st);
	chk(st == 8'h00, "READ(10) back status");
	bad = 0;
	for (int i = 0; i < 2048; i++) if (dbuf[i] != golden[9*512 + i]) bad++;
	chk(bad == 0, $sformatf("READ(10) back: %0d bytes differ", bad));
	$display("WRITE(10) + read back ok");

	// ---- READ(6), 1 block by program transfer, no ATN (no IDENTIFY) ----
	set_cdb6(8'h08, 0, 0, 8'd63, 1, 0);
	run_cmd(0, 0, 1, 6, 0, 512, 0, st);
	chk(st == 8'h00, "READ(6) status");
	bad = 0;
	for (int i = 0; i < 512; i++) if (dbuf[i] != golden[63*512 + i]) bad++;
	chk(bad == 0 && last_in == 512, $sformatf("READ(6): %0d bytes, %0d differ", last_in, bad));
	$display("READ(6) program transfer ok");

	// ---- MODE SENSE(6), all pages ----
	set_cdb6(8'h1A, 0, 8'h3F, 0, 255, 0);
	run_cmd(0, 1, 1, 6, 0, 255, 0, st);
	chk(st == 8'h00, "MODE SENSE status");
	chk(last_in == 60 && dbuf[0] == 8'd59 && dbuf[3] == 8'd8, $sformatf("MODE SENSE length %0d hdr %02x", last_in, dbuf[0]));
	chk(dbuf[12] == 8'h03 && dbuf[13] == 8'h16 && dbuf[36] == 8'h04 && dbuf[37] == 8'h16, "MODE SENSE pages");
	chk({dbuf[9], dbuf[10], dbuf[11]} == 512, "MODE SENSE block length");
	$display("MODE SENSE ok");

	// ---- read past the end: CHECK CONDITION, ILLEGAL REQUEST / LBA out of range ----
	set_cdb10(8'h28, 62, 4);
	run_cmd(0, 1, 1, 10, 1, 2048, 0, st);
	chk(st == 8'h02, $sformatf("READ past end status %02x, want 02", st));
	set_cdb6(8'h03, 0, 0, 0, 18, 0);
	run_cmd(0, 1, 1, 6, 0, 18, 0, st);
	chk(st == 8'h00 && last_in == 18, "REQUEST SENSE (range)");
	chk(dbuf[0] == 8'h70 && dbuf[2] == 8'h05 && dbuf[12] == 8'h21, $sformatf("sense %02x/%02x, want 05/21", dbuf[2], dbuf[12]));
	// unknown opcode
	set_cdb6(8'h06, 0, 0, 0, 0, 0);
	run_cmd(0, 1, 1, 6, 0, 0, 0, st);
	chk(st == 8'h02, "unknown opcode status");
	set_cdb6(8'h03, 0, 0, 0, 18, 0);
	run_cmd(0, 1, 1, 6, 0, 18, 0, st);
	chk(dbuf[2] == 8'h05 && dbuf[12] == 8'h20, $sformatf("sense %02x/%02x, want 05/20", dbuf[2], dbuf[12]));
	$display("CHECK CONDITION paths ok");

	// ---- ID 3, no image, no arbitration, no ATN ----
	set_cdb6(8'h00, 0, 0, 0, 0, 0);
	run_cmd(3, 0, 0, 6, 0, 0, 0, st);
	chk(st == 8'h02, $sformatf("ID 3 TEST UNIT READY status %02x, want 02", st));
	set_cdb6(8'h03, 0, 0, 0, 18, 0);
	run_cmd(3, 0, 0, 6, 0, 18, 0, st);
	chk(st == 8'h00 && last_in == 18, $sformatf("ID 3 REQUEST SENSE status %02x len %0d", st, last_in));
	chk(dbuf[2] == 8'h02 && dbuf[12] == 8'h3A, $sformatf("ID 3 sense %02x/%02x, want 02/3A", dbuf[2], dbuf[12]));
	set_cdb6(8'h12, 0, 0, 0, 36, 0);
	run_cmd(3, 1, 0, 6, 0, 36, 0, st);
	chk(st == 8'h00 && last_in == 36 && dbuf[0] == 8'h00, "ID 3 INQUIRY");
	$display("ID 3 (no image) ok");

	// NetBSD-style status read must see CHECK CONDITION (02), not a stale 00
	nbsd_style = 1;
	set_cdb6(8'h00, 0, 0, 0, 0, 0);
	run_cmd(3, 0, 1, 6, 0, 0, 0, st);
	chk(st == 8'h02, $sformatf("NetBSD-style TUR on ID 3 (no image): status %02x, want 02", st));
	nbsd_style = 0;

	// ---- ID 2: CD-ROM ----
	set_cdb6(8'h00, 0, 0, 0, 0, 0);
	run_cmd(2, 1, 1, 6, 0, 0, 0, st);
	chk(st == 8'h02, $sformatf("CD TEST UNIT READY with no medium: %02x, want 02", st));
	sense_is(2, 8'h02, 8'h3A, "CD no medium");
	for (int i = 0; i < CD_SECT*2048; i++) begin
		cd_dev.img[i] = 8'((i >> 11) * 8'h40 + (i >> 9) * 8'h11 + (i & 511) * 5 + (i >> 8));
		cdgold[i]     = cd_dev.img[i];
	end
	mount(2, CD_SECT * 2048, 0);              // read-only anyway
	set_cdb6(8'h12, 0, 0, 0, 36, 0);
	run_cmd(2, 1, 1, 6, 0, 36, 0, st);
	chk(st == 8'h00 && last_in == 36, "CD INQUIRY status");
	chk(dbuf[0] == 8'h05 && dbuf[1] == 8'h80 && dbuf[2] == 8'h02,
	    $sformatf("CD INQUIRY type %02x rmb %02x ver %02x, want 05 80 02", dbuf[0], dbuf[1], dbuf[2]));
	chk({dbuf[8], dbuf[9], dbuf[10], dbuf[11], dbuf[12], dbuf[13], dbuf[14], dbuf[15]} == "HP9K385 ", "CD vendor");
	chk({dbuf[16], dbuf[17], dbuf[18], dbuf[19], dbuf[20], dbuf[21], dbuf[22], dbuf[23], dbuf[24], dbuf[25], dbuf[26]}
	    == "SCSI CD-ROM", "CD product");
	set_cdb6(8'h00, 0, 0, 0, 0, 0);
	run_cmd(2, 1, 1, 6, 0, 0, 0, st);
	chk(st == 8'h02, $sformatf("CD TEST UNIT READY after mount: %02x, want 02 (unit attention)", st));
	sense_is(2, 8'h06, 8'h28, "CD unit attention");
	set_cdb6(8'h00, 0, 0, 0, 0, 0);
	run_cmd(2, 1, 1, 6, 0, 0, 0, st);
	chk(st == 8'h00, $sformatf("CD TEST UNIT READY after the unit attention: %02x", st));
	cap_is(2, CD_SECT * 4 - 1, 512, "CD at 512");

	// READ(10) at 512: LBA 3, 5 blocks
	set_cdb10(8'h28, 3, 5);
	run_cmd(2, 1, 1, 10, 1, 2560, 0, st);
	chk(st == 8'h00, "CD READ(10) at 512 status");
	bad = 0;
	for (int i = 0; i < 2560; i++) if (dbuf[i] != cdgold[3*512 + i]) bad++;
	chk(bad == 0, $sformatf("CD READ(10) at 512: %0d bytes differ", bad));

	// MODE SELECT: block length 2048
	mode_select(2, 24'd2048, st);
	chk(st == 8'h00, "CD MODE SELECT 2048 status");
	cap_is(2, CD_SECT - 1, 2048, "CD at 2048");
	set_cdb6(8'h1A, 0, 8'h00, 0, 255, 0);
	run_cmd(2, 1, 1, 6, 0, 255, 0, st);
	chk(st == 8'h00 && last_in == 12 && dbuf[0] == 8'd11 && dbuf[3] == 8'd8,
	    $sformatf("CD MODE SENSE: %0d bytes, header %02x %02x", last_in, dbuf[0], dbuf[3]));
	chk(dbuf[2][7], "CD MODE SENSE WP");
	chk(dbuf[4] == 8'h00 && {dbuf[5], dbuf[6], dbuf[7]} == CD_SECT && {dbuf[9], dbuf[10], dbuf[11]} == 2048,
	    "CD MODE SENSE block descriptor");

	// READ(10) and READ(6) at 2048
	set_cdb10(8'h28, 2, 3);
	run_cmd(2, 1, 1, 10, 1, 6144, 0, st);
	chk(st == 8'h00, "CD READ(10) at 2048 status");
	bad = 0;
	for (int i = 0; i < 6144; i++) if (dbuf[i] != cdgold[2*2048 + i]) bad++;
	chk(bad == 0, $sformatf("CD READ(10) at 2048: %0d bytes differ", bad));
	set_cdb6(8'h08, 0, 0, 8'd7, 1, 0);
	run_cmd(2, 1, 1, 6, 1, 2048, 0, st);
	chk(st == 8'h00, "CD READ(6) at 2048 status");
	bad = 0;
	for (int i = 0; i < 2048; i++) if (dbuf[i] != cdgold[7*2048 + i]) bad++;
	chk(bad == 0, $sformatf("CD READ(6) at 2048: %0d bytes differ", bad));
	set_cdb10(8'h28, 7, 2);
	run_cmd(2, 1, 1, 10, 1, 4096, 0, st);
	chk(st == 8'h02, "CD READ past the end at 2048");
	sense_is(2, 8'h05, 8'h21, "CD LBA out of range");

	// refused commands
	set_cdb10(8'h2A, 0, 1);
	run_cmd(2, 1, 1, 10, 1, 2048, 0, st);
	chk(st == 8'h02, "CD WRITE(10) status");
	sense_is(2, 8'h07, 8'h27, "CD WRITE -> DATA PROTECT");
	set_cdb6(8'h0A, 0, 0, 0, 1, 0);
	run_cmd(2, 1, 1, 6, 1, 2048, 0, st);
	chk(st == 8'h02, "CD WRITE(6) status");
	sense_is(2, 8'h07, 8'h27, "CD WRITE(6) -> DATA PROTECT");
	set_cdb6(8'h04, 0, 0, 0, 0, 0);
	run_cmd(2, 1, 1, 6, 0, 0, 0, st);
	chk(st == 8'h02, "CD FORMAT status");
	sense_is(2, 8'h05, 8'h20, "CD FORMAT -> ILLEGAL REQUEST");
	set_cdb10(8'h45, 0, 1);                  // PLAY AUDIO(10)
	run_cmd(2, 1, 1, 10, 0, 0, 0, st);
	chk(st == 8'h02, "CD PLAY AUDIO status");
	sense_is(2, 8'h05, 8'h20, "CD PLAY AUDIO -> ILLEGAL REQUEST");
	set_cdb6(8'h1B, 0, 0, 0, 2, 0);          // START STOP UNIT, eject
	run_cmd(2, 1, 1, 6, 0, 0, 0, st);
	chk(st == 8'h00, "CD START STOP UNIT");
	set_cdb6(8'h1E, 0, 0, 0, 1, 0);          // PREVENT
	run_cmd(2, 1, 1, 6, 0, 0, 0, st);
	chk(st == 8'h00, "CD PREVENT ALLOW");

	// READ TOC, LBA form (2048-byte blocks): track 1 at 0, lead-out at 8
	read_toc(0, 8'd0, 16'd804, st);
	chk(st == 8'h00 && last_in == 20, $sformatf("READ TOC: status %02x, %0d bytes", st, last_in));
	chk(dbuf[0] == 8'd0 && dbuf[1] == 8'd18 && dbuf[2] == 8'd1 && dbuf[3] == 8'd1, "READ TOC header");
	chk(dbuf[5] == 8'h14 && dbuf[6] == 8'd1 && {dbuf[8], dbuf[9], dbuf[10], dbuf[11]} == 0, "READ TOC track 1");
	chk(dbuf[13] == 8'h14 && dbuf[14] == 8'hAA && {dbuf[16], dbuf[17], dbuf[18], dbuf[19]} == CD_SECT,
	    $sformatf("READ TOC lead-out %02x %02x%02x%02x%02x", dbuf[14], dbuf[16], dbuf[17], dbuf[18], dbuf[19]));
	// MSF form: track 1 at 00:02:00, lead-out at 8 + 150 frames = 00:02:08
	read_toc(1, 8'd1, 16'd804, st);
	chk(st == 8'h00 && last_in == 20, "READ TOC MSF length");
	chk({dbuf[8], dbuf[9], dbuf[10], dbuf[11]} == 32'h00000200, "READ TOC MSF track 1");
	chk({dbuf[16], dbuf[17], dbuf[18], dbuf[19]} == 32'h00000208,
	    $sformatf("READ TOC MSF lead-out %02x:%02x:%02x", dbuf[17], dbuf[18], dbuf[19]));
	// lead-out only, allocation length, bad track
	read_toc(0, 8'hAA, 16'd804, st);
	chk(st == 8'h00 && last_in == 12 && dbuf[1] == 8'd10 && dbuf[6] == 8'hAA, "READ TOC from AAh");
	read_toc(0, 8'd0, 16'd12, st);
	chk(st == 8'h00 && last_in == 12 && dbuf[1] == 8'd18, $sformatf("READ TOC alloc 12: %0d bytes", last_in));
	read_toc(0, 8'd2, 16'd804, st);
	chk(st == 8'h02, "READ TOC track 2");
	sense_is(2, 8'h05, 8'h24, "READ TOC track 2 -> INVALID FIELD IN CDB");
	// READ SUB-CHANNEL
	cdbb[0] = 8'h42; cdbb[1] = 0; cdbb[2] = 8'h40; cdbb[3] = 8'h01; cdbb[4] = 0; cdbb[5] = 0; cdbb[6] = 0;
	cdbb[7] = 0; cdbb[8] = 8'd16; cdbb[9] = 0;
	run_cmd(2, 1, 1, 10, 0, 16, 0, st);
	chk(st == 8'h00 && last_in == 4 && dbuf[1] == 8'h15, "READ SUB-CHANNEL");

	// bad block length is refused; back to 512
	mode_select(2, 24'd1024, st);
	chk(st == 8'h02, "CD MODE SELECT 1024 status");
	sense_is(2, 8'h05, 8'h26, "CD MODE SELECT 1024 -> INVALID FIELD IN PARAMETER LIST");
	cap_is(2, CD_SECT - 1, 2048, "CD still at 2048");
	mode_select(2, 24'd512, st);
	chk(st == 8'h00, "CD MODE SELECT 512 status");
	cap_is(2, CD_SECT * 4 - 1, 512, "CD back at 512");
	read_toc(0, 8'hAA, 16'd804, st);
	chk({dbuf[8], dbuf[9], dbuf[10], dbuf[11]} == CD_SECT * 4, "READ TOC lead-out at 512");
	chk(cd_dev.errors == 0, "CD block device model errors");
	$display("CD-ROM ok (%0d block reads)", cd_dev.reads);

	// ---- several units on the one engine ----
	// ID 1 has no image yet: NOT READY, and nobody else is disturbed
	tur_is(1, 8'h02, "ID 1 before its mount");
	tur_is(0, 8'h00, "ID 0 between ID 1 commands");
	sense_is(1, 8'h02, 8'h3A, "ID 1 no medium");
	inq_is(1, 0, "ID 1 without an image");
	for (int i = 0; i < D1_BLK*512; i++) begin
		d1_dev.img[i] = 8'((i >> 9) * 8'h5B + (i & 511) * 3 + (i >> 7) + 8'h11);
		d1gold[i]     = d1_dev.img[i];
	end
	mount(1, D1_BLK * 512, 1);                // read-only
	// a disk mount raises no unit attention, on that disk or on the CD
	tur_is(1, 8'h00, "ID 1 after its mount");
	tur_is(2, 8'h00, "CD after the ID 1 mount");
	inq_is(0, 0, "ID 0"); inq_is(2, 1, "ID 2"); inq_is(1, 0, "ID 1"); inq_is(3, 0, "ID 3");
	cap_is(0, NBLK - 1, 512, "ID 0 capacity");
	cap_is(1, D1_BLK - 1, 512, "ID 1 capacity");
	cap_is(2, CD_SECT * 4 - 1, 512, "CD capacity");
	// the CD's lead-out MSF is its own (ID 1's image would give 00:02:04)
	read_toc(1, 8'hAA, 16'd804, st);
	chk(st == 8'h00 && {dbuf[8], dbuf[9], dbuf[10], dbuf[11]} == 32'h00000208,
	    $sformatf("CD MSF lead-out after the ID 1 mount %02x:%02x:%02x", dbuf[9], dbuf[10], dbuf[11]));
	$display("ID 1 mount ok");

	// reads alternating between the units
	read_is(1, 3, 2, 512, "ID 1 a");
	read_is(0, 20, 3, 512, "ID 0 a");
	read_is(2, 9, 3, 512, "CD a");
	read_is(1, 14, 2, 512, "ID 1 b");
	read_is(0, 9, 4, 512, "ID 0 b");                 // includes the blocks written above
	read_is(1, 0, 1, 512, "ID 1 c");
	$display("alternating reads ok");

	// read-only is per unit
	for (int i = 0; i < 512; i++) obuf[i] = 8'($urandom);
	set_cdb10(8'h2A, 2, 1);
	run_cmd(1, 1, 1, 10, 1, 512, 0, st);
	chk(st == 8'h02, $sformatf("ID 1 read-only WRITE(10) status %02x", st));
	sense_is(1, 8'h07, 8'h27, "ID 1 WRITE -> DATA PROTECT");
	msense_wp_is(1, 1, "ID 1 read-only");
	msense_wp_is(0, 0, "ID 0 writable");
	for (int i = 0; i < 512; i++) golden[30*512 + i] = obuf[i];
	set_cdb10(8'h2A, 30, 1);
	run_cmd(0, 1, 1, 10, 1, 512, 0, st);
	chk(st == 8'h00, $sformatf("ID 0 WRITE(10) next to read-only ID 1: %02x", st));
	read_is(0, 29, 3, 512, "ID 0 after its write");
	bad = 0;
	for (int i = 0; i < D1_BLK*512; i++) if (d1_dev.img[i] != d1gold[i]) bad++;
	chk(bad == 0, $sformatf("ID 1 image changed by writes elsewhere: %0d bytes", bad));

	// sense stays with its unit until REQUEST SENSE on that unit
	set_cdb10(8'h28, NBLK - 1, 2);
	run_cmd(0, 1, 1, 10, 1, 1024, 0, st);
	chk(st == 8'h02, "ID 0 READ past end");                 // 0: 05/21
	set_cdb6(8'h06, 0, 0, 0, 0, 0);
	run_cmd(1, 1, 1, 6, 0, 0, 0, st);
	chk(st == 8'h02, "ID 1 unknown opcode");                // 1: 05/20
	set_cdb10(8'h2A, 0, 1);
	run_cmd(2, 1, 1, 10, 1, 512, 0, st);
	chk(st == 8'h02, "CD WRITE");                           // 2: 07/27
	tur_is(3, 8'h02, "ID 3 between");                       // 3: 02/3A
	inq_is(3, 0, "ID 3 INQUIRY between");
	read_is(1, 5, 1, 512, "ID 1 between");                  // clears 1
	set_cdb6(8'h06, 0, 0, 0, 0, 0);
	run_cmd(1, 1, 1, 6, 0, 0, 0, st);                       // 1: 05/20 again
	sense_is(0, 8'h05, 8'h21, "ID 0 sense kept across other units");
	sense_is(0, 8'h00, 8'h00, "ID 0 sense consumed");
	sense_is(3, 8'h02, 8'h3A, "ID 3 sense");
	sense_is(2, 8'h07, 8'h27, "CD sense kept across other units");
	sense_is(1, 8'h05, 8'h20, "ID 1 sense kept across other units");
	sense_is(1, 8'h00, 8'h00, "ID 1 sense consumed");
	sense_is(2, 8'h00, 8'h00, "CD sense consumed");
	$display("per-unit sense ok");

	// the block length is the CD's own; a disk's MODE SELECT changes nothing
	mode_select(2, 24'd2048, st);
	chk(st == 8'h00, "CD MODE SELECT 2048 (multi)");
	mode_select(0, 24'd2048, st);
	chk(st == 8'h00, "ID 0 MODE SELECT 2048");
	cap_is(0, NBLK - 1, 512, "ID 0 stays at 512");
	cap_is(1, D1_BLK - 1, 512, "ID 1 stays at 512");
	cap_is(2, CD_SECT - 1, 2048, "CD at 2048 (multi)");
	read_is(2, 5, 2, 2048, "CD 2048 a");
	read_is(1, 7, 2, 512, "ID 1 next to a 2048 CD");
	read_is(2, 0, 1, 2048, "CD 2048 b");
	read_is(0, 40, 2, 512, "ID 0 next to a 2048 CD");
	read_toc(0, 8'd0, 16'd804, st);
	chk(st == 8'h00 && last_in == 20 && {dbuf[16], dbuf[17], dbuf[18], dbuf[19]} == CD_SECT,
	    "READ TOC at 2048 (multi)");
	// a disk has no READ TOC, and no MSF
	read_toc_on(1, 1, 8'd0, 16'd804, st);
	chk(st == 8'h02, "READ TOC on a disk");
	sense_is(1, 8'h05, 8'h20, "READ TOC on a disk -> ILLEGAL REQUEST");

	// remount ID 1 writable: the CD keeps its block length and has no unit attention
	mount(1, D1_BLK * 512, 0);
	tur_is(2, 8'h00, "CD after the ID 1 remount");
	cap_is(2, CD_SECT - 1, 2048, "CD still at 2048 after the ID 1 remount");
	for (int i = 0; i < 1024; i++) begin
		obuf[i] = 8'($urandom);
		d1gold[6*512 + i] = obuf[i];
	end
	set_cdb10(8'h2A, 6, 2);
	run_cmd(1, 1, 1, 10, 1, 1024, 0, st);
	chk(st == 8'h00, "ID 1 WRITE(10) after the writable remount");
	bad = 0;
	for (int i = 0; i < D1_BLK*512; i++) if (d1_dev.img[i] != d1gold[i]) bad++;
	chk(bad == 0, $sformatf("ID 1 image after its WRITE(10): %0d bytes differ", bad));
	bad = 0;
	for (int i = 0; i < NBLK*512; i++) if (img[i] != golden[i]) bad++;
	chk(bad == 0, $sformatf("ID 0 image after the ID 1 WRITE(10): %0d bytes differ", bad));
	read_is(1, 5, 4, 512, "ID 1 read back");

	// remount the CD bigger: unit attention on the CD only, back to 512, new MSF
	mount(2, 64'd10000 * 2048, 0);           // 10150 frames: 02:15:25
	tur_is(0, 8'h00, "ID 0 after the CD remount");
	tur_is(1, 8'h00, "ID 1 after the CD remount");
	tur_is(2, 8'h02, "CD after its remount");
	sense_is(2, 8'h06, 8'h28, "CD remount unit attention");
	cap_is(2, 10000 * 4 - 1, 512, "CD remounted at 512");
	read_toc(1, 8'hAA, 16'd804, st);
	chk(st == 8'h00 && {dbuf[8], dbuf[9], dbuf[10], dbuf[11]} == 32'h00020F19,
	    $sformatf("CD MSF lead-out after the remount %02x:%02x:%02x", dbuf[9], dbuf[10], dbuf[11]));
	mount(2, CD_SECT * 2048, 0);
	tur_is(2, 8'h02, "CD after the second remount");
	tur_is(2, 8'h00, "CD after its unit attention");
	read_is(2, 13, 3, 512, "CD after the second remount");
	chk(cd_dev.errors == 0 && d1_dev.errors == 0, "block device model errors");
	$display("multi-unit ok (ID 1 %0d reads %0d writes)", d1_dev.reads, d1_dev.writes);

	// SCSI RST while ID 0 waits for its block: the request stays up until
	// the HPS takes it, and ID 1's next request must wait for that block
	// to finish (the one sd_lba and buffer are shared)
	slow0 = 20000;
	select(0, 1, 1, v);
	chk(v == 8'h10, $sformatf("RST test select: INTS %02x", v));
	clr_ints(v);
	begin
		reg [2:0] ph;
		wait_req(ph);
		obuf[0] = 8'h80;
		prg_out(3'd6, 1, 0);
		wait_req(ph);
		chk(ph == 3'd2, $sformatf("RST test: phase %0d, want COMMAND", ph));
		set_cdb10(8'h28, 33, 1);
		prg_out(3'd2, 10, 1);
	end
	wait (t_rd[0]);
	repeat (50) @(negedge clk);
	wr(SCMD, 8'h10);                         // RST on
	repeat (20) @(negedge clk);
	wr(SCMD, 8'h00);                         // and off
	chk(t_rd[0], "ID 0 request dropped by SCSI RST");
	rd(INTS, v);
	if (v != 8'h00) clr_ints(v);
	wr(PCTL, 8'h00);
	slow0 = 0;
	read_is(1, 11, 1, 512, "ID 1 after RST with ID 0's block pending");
	read_is(0, 33, 2, 512, "ID 0 after RST");
	$display("SCSI RST with a block pending ok");

	// ---- ID 5 absent: selection time-out ----
	select(5, 1, 1, v);
	chk(v == 8'h04, $sformatf("absent ID 5: INTS %02x, want 04", v));
	rd(SSTS, s); chk(s[7] && s[5], $sformatf("SSTS %02x during selection time-out", s));
	rd(PSNS, p); chk(p[4] && !p[3], $sformatf("PSNS %02x during selection time-out", p));
	rd(TCL, v);  chk(v == 8'h00, "TC not cleared by the time-out");
	clr_ints(8'h04);                         // TC = 0: terminate
	rd(SSTS, s); chk(s[7:4] == 4'h0, $sformatf("SSTS %02x after terminating the selection", s));
	rd(PSNS, p); chk(p == 8'h00, $sformatf("PSNS %02x after terminating the selection", p));
	$display("selection time-out ok");

	// ---- and the bus still works ----
	set_cdb6(8'h00, 0, 0, 0, 0, 0);
	run_cmd(0, 1, 1, 6, 0, 0, 0, st);
	chk(st == 8'h00, "TEST UNIT READY after the time-out");

	repeat (20) @(negedge clk);
	if (errors == 0) $display("ALL TESTS PASSED");
	else             $display("FAILED: %0d errors", errors);
	$finish;
end

initial begin
	#200ms;
	$display("FAIL: global timeout");
	$finish;
end

endmodule

//============================================================================
//  tb_blkdev — hps_io-timed block device (WIDE=1, 512-byte blocks,
//  little-endian words) with its image in `img`.
//============================================================================
module tb_blkdev
#(
	parameter NBLK = 32
)
(
	input             clk,
	input             reset,
	input      [31:0] sd_lba,
	input             sd_rd,
	input             sd_wr,
	output reg        sd_ack = 0,
	output reg  [7:0] sd_buff_addr = 0,
	output reg [15:0] sd_buff_dout = 0,
	output reg        sd_buff_wr = 0,
	input      [15:0] sd_buff_din
);

reg [7:0] img [0:NBLK*512-1];
integer   errors = 0, reads = 0, writes = 0;

task automatic err(input string what);
	errors++;
	$display("FAIL @%0t: %m: %s", $time, what);
endtask

initial begin
	forever begin
		@(negedge clk);
		if (!reset && (sd_rd || sd_wr)) begin
			bit isrd;
			int l;
			isrd = sd_rd;
			l    = sd_lba;
			if (sd_rd && sd_wr) err("sd_rd and sd_wr together");
			if (l >= NBLK) err($sformatf("sd_lba %0d out of range", l));
			repeat ($urandom_range(5, 60)) begin
				@(negedge clk);
				if (!(isrd ? sd_rd : sd_wr)) err("block request dropped before sd_ack");
				if (sd_lba != l) err("sd_lba changed while requesting");
			end
			sd_ack       = 1;
			sd_buff_addr = 0;
			repeat (2) @(negedge clk);
			if (sd_rd || sd_wr) err("block request still up after sd_ack");
			for (int w = 0; w < 256; w++) begin
				sd_buff_addr = w;
				if (isrd) begin
					sd_buff_dout = (l < NBLK) ? {img[l*512 + 2*w + 1], img[l*512 + 2*w]} : 16'h0000;
					@(negedge clk); sd_buff_wr = 1;
					@(negedge clk); sd_buff_wr = 0;
					@(negedge clk);
				end
				else begin
					repeat ($urandom_range(2, 4)) @(negedge clk);
					if (l < NBLK) {img[l*512 + 2*w + 1], img[l*512 + 2*w]} = sd_buff_din;
				end
			end
			repeat (2) @(negedge clk);
			sd_ack = 0;
			if (isrd) reads++; else writes++;
		end
	end
end

endmodule
