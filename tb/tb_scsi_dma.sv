//============================================================================
//  tb_scsi_dma — the 98265A card (hp98265a: MB87030 + the shared target
//  engine) and the 98620 DMA controller (hp98620) with a memory model,
//  driven the way the boot ROM and then NetBSD's spc driver drive them:
//
//    1. ROM-style: a READ(10) of 2 blocks from ID 0 by DMA on channel 0
//       (98620C register set, longword units, card DE0), polled.
//    2. NetBSD 9 attach (sys/arch/hp300/dev/spc.c spc_dio_attach and
//       sys/dev/ic/mb89352.c spc_init): card reset through the ID register,
//       CSR = 0, HCONF = 0, spc_reset, SCSI bus reset, spc_reset, SCTL IE,
//       CSR = IE.  The 98620 is not reset, as on the real machine.
//    3. NetBSD's probe of IDs 0, 1 and 2: selection without ATN, TEST UNIT
//       READY, then INQUIRY of 36 bytes.  36 > SPC_MIN_DMA_LEN (32), so the
//       data goes by DMA: dmareq() hands out channel 1 first, dmago() arms
//       it with longword units and no interrupt, spc_dio_dmago() writes
//       CSR = IE|DMAIN|DMA32 then |DE1 and starts a padded DMA transfer.
//       At command complete spc_dio_dmadone() waits for SSTS busy to drop,
//       clears the channel (DMA_CLEAR), drops DE0/DE1 and reads TC back.
//       STATUS and MESSAGE IN are read from TEMP before SET ACK.  A CHECK
//       CONDITION is followed by REQUEST SENSE (18 bytes, program transfer).
//
//  On the board, step 3 gave INQUIRY byte 0 = 0xFF (OpenBSD: "31/vendor-
//  unique", NetBSD: "scsipi_dtype: impossible device type") on the first
//  unit probed only.
//
//  Build:  verilator --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_scsi_dma
//          tb/tb_scsi_dma.sv tb/tb_scsi.sv rtl/hp98265a.sv rtl/hp98620.sv
//          rtl/scsi/mb87030.sv rtl/scsi/scsi_target.sv
//  (tb_scsi.sv only for its tb_blkdev block-device model.)
//============================================================================

`timescale 1ns/1ps

module tb_scsi_dma;

localparam NBLK = 64;

// SPC registers
localparam [3:0] BDID = 0, SCTL = 1, SCMD = 2, TMOD = 3, INTS = 4, PSNS = 5, SSTS = 6,
                 SERR = 7, PCTL = 8, MBC = 9, DREG = 10, TEMP = 11, TCH = 12, TCM = 13,
                 TCL = 14, EXBF = 15;
// card CSR (HPSCSI_CSR)
localparam [7:0] CSR_IE = 8'h80, CSR_DMA32 = 8'h08, CSR_DMAIN = 8'h04, CSR_DE1 = 8'h02, CSR_DE0 = 8'h01;

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
// the card and the DMA controller
//----------------------------------------------------------------------------
reg         c_cs = 0, c_we = 0;
reg  [10:1] c_off = 0;
reg   [1:0] c_be = 0;
reg  [15:0] c_din = 0;
wire [15:0] c_dout;
wire        c_irq;
wire  [1:0] dmar;
wire        dack_rd, dack_wr, dack_ch;
wire  [7:0] dack_wdata, dack_rdata;

reg   [2:0] img_mounted = 0;
reg  [63:0] img_size = 0;
wire [95:0] sd_lba;
wire  [2:0] sd_rd, sd_wr;
wire        d0_ack, d0_bwr;
wire  [7:0] d0_baddr;
wire [15:0] d0_bdout;
wire [47:0] sd_buff_din;

hp98265a card (
	.clk(clk), .reset(reset),
	.reg_cs(c_cs), .reg_we(c_we), .reg_off(c_off), .reg_be(c_be), .reg_din(c_din), .reg_dout(c_dout),
	.irq(c_irq), .dmar(dmar),
	.dack_rd(dack_rd), .dack_wr(dack_wr), .dack_ch(dack_ch), .dack_wdata(dack_wdata), .dack_rdata(dack_rdata),
	.img_mounted(img_mounted), .img_size(img_size), .img_readonly(1'b0),
	.sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack({2'b00, d0_ack}),
	.sd_buff_addr(d0_baddr), .sd_buff_dout(d0_bdout), .sd_buff_wr(d0_bwr), .sd_buff_din(sd_buff_din)
);

// ID 0: a 64-block disk; IDs 1 (disk) and 2 (CD) have no image
tb_blkdev #(.NBLK(NBLK)) d0 (
	.clk(clk), .reset(reset),
	.sd_lba(sd_lba[31:0]), .sd_rd(sd_rd[0]), .sd_wr(sd_wr[0]), .sd_ack(d0_ack),
	.sd_buff_addr(d0_baddr), .sd_buff_dout(d0_bdout), .sd_buff_wr(d0_bwr), .sd_buff_din(sd_buff_din[15:0])
);

reg         d_cs = 0, d_we = 0;
reg   [9:1] d_word = 0;
reg   [1:0] d_be = 2'b11;
reg  [15:0] d_din = 0;
wire [15:0] d_dout;
wire        mreq, mwe;
wire [31:0] maddr;
wire  [7:0] mwdata;
reg         mack = 0, merr = 0;
reg  [31:0] mrdata = 0;
wire  [7:1] dma_irq;

hp98620 dma (
	.clk(clk), .reset(reset),
	.reg_cs(d_cs), .reg_we(d_we), .reg_word(d_word), .reg_be(d_be), .reg_din(d_din), .reg_dout(d_dout),
	.dmar(dmar),
	.dack_rd(dack_rd), .dack_wr(dack_wr), .dack_ch(dack_ch), .dack_wdata(dack_wdata), .dack_rdata(dack_rdata),
	.mreq(mreq), .mwe(mwe), .maddr(maddr), .mwdata(mwdata), .mack(mack), .mrdata(mrdata), .merr(merr),
	.irq_lvl(dma_irq)
);

// memory: 16 KB at 0x10000, byte writes, longword reads, 1-4 clocks
localparam MBASE = 32'h0001_0000;
reg [7:0] mem [0:16383];
integer mlat = 0;
always @(posedge clk) begin
	mack <= 0; merr <= 0;
	if (mreq && !mack && !merr) begin
		if (mlat == 0) mlat <= $urandom_range(1, 4);
		else if (mlat == 1) begin
			mlat <= 0;
			if (maddr < MBASE || maddr >= MBASE + 16384) merr <= 1;
			else begin
				if (mwe) mem[maddr - MBASE] <= mwdata;
				mrdata <= {mem[{maddr[31:2], 2'd0} - MBASE], mem[{maddr[31:2], 2'd1} - MBASE],
				           mem[{maddr[31:2], 2'd2} - MBASE], mem[{maddr[31:2], 2'd3} - MBASE]};
				mack <= 1;
			end
		end
		else mlat <= mlat - 1;
	end
end

always @(posedge clk)
	if (!reset && merr) chk(0, $sformatf("DMA bus error at %08x", maddr));

//----------------------------------------------------------------------------
// CPU accesses: card bytes (odd byte = reg_be[0]), SPC registers, 98620
//----------------------------------------------------------------------------
int acc_dly = 10;                           // extra clocks per card access: the core's io16 path never
                                             // takes fewer (the boot ROM's SPC accesses are ~70 apart)
task automatic card_wr(input [10:1] w, input [7:0] d);
	repeat (acc_dly) @(negedge clk);
	@(negedge clk); c_cs = 1; c_we = 1; c_off = w; c_be = 2'b01; c_din = {8'h00, d};
	@(negedge clk); c_cs = 0; c_we = 0;
endtask

task automatic card_rd(input [10:1] w, output [7:0] d);
	repeat (acc_dly) @(negedge clk);
	@(negedge clk); c_cs = 1; c_we = 0; c_off = w; c_be = 2'b01; #1; d = c_dout[7:0];
	@(negedge clk); c_cs = 0;
endtask

task automatic wr(input [3:0] r, input [7:0] d);
	card_wr(10'h10 + r, d);
endtask

task automatic rd(input [3:0] r, output [7:0] d);
	card_rd(10'h10 + r, d);
endtask

task automatic dwr(input [9:0] off, input [15:0] d);
	@(negedge clk); d_cs = 1; d_we = 1; d_word = off[9:1]; d_be = 2'b11; d_din = d;
	@(negedge clk); d_cs = 0; d_we = 0;
endtask

task automatic drd(input [9:0] off, output [15:0] d);
	@(negedge clk); d_cs = 1; d_we = 0; d_word = off[9:1]; d_be = 2'b11; #1; d = d_dout;
	@(negedge clk); d_cs = 0;
endtask

task automatic delay_us(input int n);
	repeat (n * 33) @(negedge clk);
endtask

//----------------------------------------------------------------------------
// NetBSD's driver (one command at a time, interrupt-driven unless polled)
//----------------------------------------------------------------------------
localparam [7:0] SCTL_DISABLE = 8'h80, SCTL_CTRLRST = 8'h40, SCTL_ABRT_ENAB = 8'h10,
                 SCTL_PARITY_ENAB = 8'h08, SCTL_RESEL_ENAB = 8'h02, SCTL_INTR_ENAB = 8'h01;

task automatic spc_reset();
	reg [7:0] v;
	wr(SCTL, SCTL_DISABLE | SCTL_CTRLRST);
	wr(SCMD, 0); wr(TMOD, 0); wr(PCTL, 0); wr(TEMP, 0);
	wr(TCH, 0); wr(TCM, 0); wr(TCL, 0); wr(INTS, 0);
	wr(SCTL, SCTL_DISABLE | SCTL_ABRT_ENAB | SCTL_PARITY_ENAB | SCTL_RESEL_ENAB);
	wr(BDID, 7);
	delay_us(400);
	rd(SCTL, v); wr(SCTL, v & ~SCTL_DISABLE);
endtask

task automatic spc_scsi_reset();
	reg [7:0] v;
	rd(SCMD, v); wr(SCMD, v | 8'h10);
	delay_us(500);
	rd(SCMD, v); wr(SCMD, v & ~8'h10);
	delay_us(50);
endtask

// the 98620 as dma.c drives it: DMA_ARM on the 98620C set, DMA_CLEAR
// through the 98620B address register (a longword read)
task automatic dma_arm(input int ch, input [31:0] addr, input [31:0] cnt, input [15:0] cmd);
	reg [9:0] b;
	b = ch ? 10'h200 : 10'h100;
	dwr(b + 0, addr[31:16]); dwr(b + 2, addr[15:0]);
	dwr(b + 4, cnt[31:16]);  dwr(b + 6, cnt[15:0]);
	dwr(b + 8, cmd);
endtask

task automatic dma_clear(input int ch);
	reg [15:0] x;
	drd(ch ? 10'h008 : 10'h000, x); drd(ch ? 10'h00A : 10'h002, x);
endtask

// wait for the card interrupt (or poll INTS) and return INTS
bit polled = 0;
task automatic wait_intr(output [7:0] ints);
	int n;
	n = 0;
	if (polled) begin
		do begin rd(INTS, ints); n++; end while (ints == 8'h00 && n < 2000000);
	end
	else begin
		while (!c_irq && n < 4000000) begin @(negedge clk); n++; end
		rd(INTS, ints);
	end
	chk(ints != 8'h00, "timeout waiting for the SPC interrupt");
endtask

task automatic wait_req(output [2:0] ph);
	reg [7:0] p;
	int n;
	n = 0;
	do begin rd(PSNS, p); n++; end while (!p[7] && n < 2000000);
	chk(p[7], "timeout waiting for REQ");
	ph = p[2:0];
endtask

// STATUS / MESSAGE IN: the byte is read from TEMP before SET ACK
task automatic manual_in(input [2:0] ph, output [7:0] b);
	reg [7:0] p;
	rd(PSNS, p);
	if (p[5]) wr(SCMD, 8'h40);                 // reset ATN
	wr(PCTL, 8'h80 | ph);
	do rd(PSNS, p); while (!p[7]);
	rd(TEMP, b);
	wr(SCMD, 8'hE0);                           // set ACK
	do rd(PSNS, p); while (p[7]);
	wr(SCMD, 8'hC0);                           // reset ACK
endtask

// spc_dataout_pio
task automatic pio_out(input [2:0] ph, input [7:0] buf_[16], input int n);
	reg [7:0] s, v;
	int i, k;
	wr(TCH, n >> 16); wr(TCM, n >> 8); wr(TCL, n);
	wr(PCTL, 8'h80 | ph);
	wr(SCMD, 8'h84);
	do begin rd(SSTS, s); rd(INTS, v); end while (!s[5] && v == 0);
	i = 0;
	while (i < n) begin
		do begin rd(INTS, v); rd(SSTS, s); end while (!s[0] && v == 0);
		if (v != 0) break;
		for (k = 0; k < 8 && i < n; k++) begin wr(DREG, buf_[i]); i++; end
	end
	do rd(INTS, v); while (v == 0);
endtask

// spc_datain_pio into mem[off...], as NetBSD has it: the loop ends when n
// bytes are read, without waiting for the SPC to finish the handshake of the
// last one; n = 0 (the target still offering DATA IN) drains the FIFO until
// INTS is set
task automatic pio_in(input [2:0] ph, input int off, input int n, output int got);
	reg [7:0] s, v, b;
	wr(TCH, n >> 16); wr(TCM, n >> 8); wr(TCL, n);
	wr(PCTL, 8'h80 | ph);
	wr(SCMD, 8'h84);
	got = 0;
	v = 0;
	while (n > 0) begin
		rd(SSTS, s);
		if (s[1]) begin for (int k = 0; k < 8; k++) begin rd(DREG, b); mem[off + got] = b; got++; end n -= 8; end
		else if (!s[0]) begin rd(DREG, b); mem[off + got] = b; got++; n--; end
		else begin
			if (v != 0) return;
			rd(INTS, v);
		end
	end
	if (got == 0) forever begin
		rd(SSTS, s);
		if (!s[0]) rd(DREG, b);
		else begin
			if (v != 0) return;
			rd(INTS, v);
		end
		delay_us(1);
	end
endtask

// one command, the way spc_intr runs it; data in by DMA if > 32 bytes
integer dma_ch = 1;                         // the channel dmareq() hands out
task automatic nb_cmd(input int tgt, input [7:0] cdb[16], input int clen, input int dlen,
                      input int off, output [7:0] stat, output int got);
	reg [7:0] ints, v, s, p, m, cmd;
	reg [2:0] ph;
	bit doing_dma, done;
	int resid, guard;
	int dleft; stat = 8'hFF; got = 0; doing_dma = 0; done = 0; guard = 0; dleft = dlen;
	// spc_select
	wr(PCTL, 0);
	wr(TEMP, 8'h80 | (8'd1 << tgt));
	wr(TCH, 2); wr(TCM, 113); wr(TCL, 3);
	wr(SCMD, 8'h20);
	wait_intr(ints);
	chk(ints == 8'h10, $sformatf("ID %0d: selection INTS %02x", tgt, ints));
	while (!done && guard < 20) begin
		guard++;
		// dophase
		wr(INTS, ints);
		wait_req(ph);
		case (ph)
		3'd2: begin
			pio_out(3'd2, cdb, clen);
			rd(INTS, ints);
		end
		3'd1: begin
			if (dleft > 32) begin
				// spc_dio_dmago
				reg [15:0] dcmd;
				card_wr(10'h3, 8'h00);                     // HCONF
				cmd = CSR_IE | CSR_DMAIN;
				dcmd = 16'h8000 | 16'h0010;                // START | IPL 4, no ENAB (NOINT)
				if ((off & 3) == 0 && (dlen & 3) == 0) begin
					cmd = cmd | CSR_DMA32;
					dcmd = dcmd | 16'h0100;                // LWORD
					dma_arm(dma_ch, MBASE + off, dlen / 4 - 1, dcmd);
				end
				else begin
					dcmd = dcmd | 16'h0002;                // WORD
					dma_arm(dma_ch, MBASE + off, dlen / 2 - 1, dcmd);
				end
				card_wr(10'h1, cmd);
				cmd = cmd | (dma_ch ? CSR_DE1 : CSR_DE0);
				card_wr(10'h1, cmd);
				wr(TCH, dlen >> 16); wr(TCM, dlen >> 8); wr(TCL, dlen);
				wr(PCTL, 8'h80 | 8'd1);
				wr(SCMD, (dlen & 511) ? 8'h81 : 8'h80);
				doing_dma = 1;
				// out: SCTL |= IE; the next interrupt
				wait_intr(ints);
				// spc_dio_dmadone
				do rd(SSTS, s); while (s[5]);
				dma_clear(dma_ch);
				card_rd(10'h1, cmd);
				card_wr(10'h1, cmd & ~(CSR_DE1 | CSR_DE0));
				rd(TCH, v); resid = v << 16;
				rd(TCM, v); resid = resid | (v << 8);
				rd(TCL, v); resid = resid | v;
				got = dlen - resid;
				rd(INTS, ints);
				chk(ints == 8'h10, $sformatf("ID %0d: DMA in INTS %02x", tgt, ints));
				dleft -= got;
			end
			else begin
				begin int g; pio_in(3'd1, off + got, dleft, g); got += g; dleft -= g; end
				rd(INTS, ints);
			end
		end
		3'd0: begin                                    // DATA OUT, always by DMA here
			reg [15:0] dcmd;
			card_wr(10'h3, 8'h00);                     // HCONF
			cmd = CSR_IE | CSR_DMA32;
			dcmd = 16'h8000 | 16'h0010 | 16'h0100 | 16'h0004;   // START | IPL 4 | LWORD | OUT
			dma_arm(dma_ch, MBASE + off, dlen / 4 - 1, dcmd);
			card_wr(10'h1, cmd);
			cmd = cmd | (dma_ch ? CSR_DE1 : CSR_DE0);
			card_wr(10'h1, cmd);
			wr(TCH, dlen >> 16); wr(TCM, dlen >> 8); wr(TCL, dlen);
			wr(PCTL, 8'h80 | 8'd0);
			wr(SCMD, 8'h80);
			wait_intr(ints);
			do rd(SSTS, s); while (s[5]);
			dma_clear(dma_ch);
			card_rd(10'h1, cmd);
			card_wr(10'h1, cmd & ~(CSR_DE1 | CSR_DE0));
			rd(TCH, v); resid = v << 16;
			rd(TCM, v); resid = resid | (v << 8);
			rd(TCL, v); resid = resid | v;
			got = dlen - resid;
			rd(INTS, ints);
			chk(ints == 8'h10, $sformatf("ID %0d: DMA out INTS %02x", tgt, ints));
			dleft -= got;
		end
		3'd3: begin
			manual_in(3'd3, stat);
			rd(INTS, ints);                            // spc_intr: goto loop
		end
		3'd7: begin
			manual_in(3'd7, m);
			chk(m == 8'h00, $sformatf("ID %0d: MESSAGE IN %02x", tgt, m));
			wait_intr(ints);
			chk(ints == 8'h20, $sformatf("ID %0d: bus free INTS %02x", tgt, ints));
			rd(PCTL, v); wr(PCTL, v & 8'h7F);
			wr(INTS, ints);
			done = 1;
		end
		default: begin
			chk(0, $sformatf("ID %0d: unexpected phase %0d", tgt, ph));
			done = 1;
		end
		endcase
	end
	chk(done, $sformatf("ID %0d: command %02x did not finish", tgt, cdb[0]));
endtask

//----------------------------------------------------------------------------
// the test
//----------------------------------------------------------------------------
reg [7:0] cdb [16];
reg [7:0] st, v;
int got;

task automatic probe(input int tgt, input [7:0] dtype, input [7:0] rmb, input string prod, input [7:0] tur_stat);
	reg [7:0] exp [36];
	string vend;
	vend = "HP9K385 ";
	for (int i = 0; i < 16; i++) cdb[i] = 0;
	// TEST UNIT READY
	nb_cmd(tgt, cdb, 6, 0, 0, st, got);
	chk(st == tur_stat, $sformatf("ID %0d: TEST UNIT READY status %02x, want %02x", tgt, st, tur_stat));
	if (st == 8'h02) begin
		cdb[0] = 8'h03; cdb[4] = 18;
		nb_cmd(tgt, cdb, 6, 18, 'h100, st, got);
		chk(st == 8'h00 && got == 18, $sformatf("ID %0d: REQUEST SENSE status %02x, %0d bytes", tgt, st, got));
		chk(mem['h102] == 8'h02 && mem['h10C] == 8'h3A,
		    $sformatf("ID %0d: sense %02x/%02x, want 02/3A", tgt, mem['h102], mem['h10C]));
	end
	// INQUIRY, 36 bytes, into a longword-aligned buffer pre-filled like scsi_probe_device
	for (int i = 0; i < 64; i++) mem['h200 + i] = 8'hA5;
	for (int i = 0; i < 16; i++) cdb[i] = 0;
	cdb[0] = 8'h12; cdb[4] = 36;
	nb_cmd(tgt, cdb, 6, 36, 'h200, st, got);
	chk(st == 8'h00 && got == 36, $sformatf("ID %0d: INQUIRY status %02x, %0d bytes", tgt, st, got));
	for (int i = 0; i < 36; i++) exp[i] = 8'h00;
	exp[0] = dtype; exp[1] = rmb; exp[2] = 8'h02; exp[3] = 8'h02; exp[4] = 8'd31;
	for (int i = 0; i < 8; i++) exp[8 + i] = vend[i];
	for (int i = 0; i < 16; i++) exp[16 + i] = prod[i];
	exp[32] = "1"; exp[33] = "."; exp[34] = "0"; exp[35] = " ";
	for (int i = 0; i < 36; i++)
		chk(mem['h200 + i] == exp[i], $sformatf("ID %0d: INQUIRY byte %0d = %02x, want %02x", tgt, i, mem['h200 + i], exp[i]));
	chk(mem['h200 + 36] == 8'hA5, "INQUIRY DMA wrote past the end of the buffer");
	$display("ID %0d: INQUIRY type %02x RMB %02x \"%s\"", tgt, mem['h200], mem['h201], prod);
endtask

initial begin
	reg [15:0] w;
	for (int i = 0; i < NBLK * 512; i++) d0.img[i] = $urandom;
	repeat (10) @(negedge clk);
	reset = 0;
	repeat (10) @(negedge clk);
	@(negedge clk); img_size = NBLK * 512; img_mounted = 3'b001;
	@(negedge clk); img_mounted = 0;

	//---- 1. the boot ROM: READ(10) LBA 1, 2 blocks, DMA channel 0, polled ----
	$display("-- ROM-style READ(10) by DMA on channel 0");
	polled = 1;
	dma_ch = 0;
	card_wr(10'h0, 8'h00);                    // card reset
	spc_reset();
	for (int i = 0; i < 16; i++) cdb[i] = 0;
	cdb[0] = 8'h28; cdb[5] = 1; cdb[8] = 2;
	nb_cmd(0, cdb, 10, 1024, 'h1000, st, got);
	chk(st == 8'h00 && got == 1024, $sformatf("ROM READ(10): status %02x, %0d bytes", st, got));
	begin
		int bad;
		bad = 0;
		for (int i = 0; i < 1024; i++) if (mem['h1000 + i] != d0.img[512 + i]) bad++;
		chk(bad == 0, $sformatf("ROM READ(10): %0d bytes differ from the image", bad));
	end
	drd(10'h104, w); chk(w == 16'hFFFF, $sformatf("DMA channel 0 count high %04x, want FFFF", w));
	drd(10'h106, w); chk(w == 16'hFFFF, $sformatf("DMA channel 0 count low %04x, want FFFF", w));

	//---- 2. NetBSD attach ----
	$display("-- NetBSD spc_dio_attach / spc_init");
	card_wr(10'h0, 8'hFF);                    // HPSCSI_ID: card reset
	delay_us(100);
	card_rd(10'h0, v);
	chk(v == 8'h07, $sformatf("card ID %02x, want 07 (32-bit DMA)", v));
	card_wr(10'h1, 8'h00);                    // CSR
	card_wr(10'h3, 8'h00);                    // HCONF
	spc_reset();
	spc_scsi_reset();
	spc_reset();
	rd(SCTL, v); wr(SCTL, v | SCTL_INTR_ENAB);
	card_wr(10'h1, CSR_IE);

	//---- HP-UX 9's bus reset: SCMD = RST, SCTL = C0, SCMD = 0 ----
	$display("-- SCSI RST ended by SCTL reset & disable");
	wr(SCTL, 8'h11);
	wr(SCMD, 8'h10);
	delay_us(30);
	chk(card.bus_c[8], "RST not on the bus after SCMD = 10");
	wr(SCTL, 8'hC0);
	repeat (2) @(negedge clk);
	chk(!card.bus_c[8], "RST still on the bus after SCTL = C0");
	// registers keep what is written while SCTL[7] is set (the boot ROM's
	// register test writes and reads them back in that state), and an RST
	// command then does not reach the bus
	wr(SCMD, 8'h10);
	rd(SCMD, v); chk(v == 8'h10, $sformatf("SCMD %02x with SCTL[7] set, want 10 (written)", v));
	delay_us(5);
	chk(!card.bus_c[8], "RST on the bus after SCMD = 10 with SCTL[7] set");
	wr(SCMD, 8'h00);
	delay_us(5);
	chk(!card.bus_c[8], "RST on the bus after SCMD = 0 with SCTL[7] set");
	wr(SCTL, SCTL_ABRT_ENAB | SCTL_PARITY_ENAB | SCTL_RESEL_ENAB | SCTL_INTR_ENAB);
	chk(!card.bus_c[8], "RST on the bus after SCTL[7] is cleared");
	// the target is out of reset: ID 0 answers (selected and probed below)

	//---- 3. the probe ----
	polled = 0;
	dma_ch = 1;
	probe(0, 8'h00, 8'h00, "SCSI DISK       ", 8'h00);
	probe(1, 8'h00, 8'h00, "SCSI DISK       ", 8'h02);
	probe(2, 8'h05, 8'h80, "SCSI CD-ROM     ", 8'h02);
	// and back to channel 0 for one more
	dma_ch = 0;
	probe(0, 8'h00, 8'h00, "SCSI DISK       ", 8'h00);
	// a slower CPU on the sense path
	acc_dly = 8;
	dma_ch = 1;
	probe(1, 8'h00, 8'h00, "SCSI DISK       ", 8'h02);

	//---- 4. an 8 KB file-system block (HP-UX HFS) written and read back by
	// longword DMA, timed ----
	$display("-- WRITE(10) and READ(10) of 16 blocks by DMA, timed");
	acc_dly = 10;
	begin
		int bad, w0, r0;
		time t0;
		for (int i = 0; i < 8192; i++) mem['h2000 + i] = $urandom;
		for (int i = 0; i < 16; i++) cdb[i] = 0;
		cdb[0] = 8'h2A; cdb[5] = 8; cdb[8] = 16;
		w0 = d0.writes; t0 = $time;
		nb_cmd(0, cdb, 10, 8192, 'h2000, st, got);
		chk(st == 8'h00 && got == 8192, $sformatf("WRITE(10): status %02x, %0d bytes", st, got));
		$display("WRITE(10) 16 blocks: %0d clocks, %0d block requests", ($time - t0) / 30, d0.writes - w0);
		bad = 0;
		for (int i = 0; i < 8192; i++) if (d0.img[8 * 512 + i] != mem['h2000 + i]) bad++;
		chk(bad == 0, $sformatf("WRITE(10): %0d bytes differ in the image", bad));
		for (int i = 0; i < 8192; i++) mem[i] = 8'h00;
		cdb[0] = 8'h28;
		r0 = d0.reads; t0 = $time;
		nb_cmd(0, cdb, 10, 8192, 'h0000, st, got);
		chk(st == 8'h00 && got == 8192, $sformatf("READ(10): status %02x, %0d bytes", st, got));
		$display("READ(10) 16 blocks: %0d clocks, %0d block requests", ($time - t0) / 30, d0.reads - r0);
		bad = 0;
		for (int i = 0; i < 8192; i++) if (mem[i] != mem['h2000 + i]) bad++;
		chk(bad == 0, $sformatf("READ(10) after WRITE(10): %0d bytes differ", bad));
	end

	errors += d0.errors;
	if (errors == 0) $display("ALL TESTS PASSED");
	else $display("TEST FAILED: %0d errors", errors);
	$finish;
end

initial begin
	#2s;
	$display("TEST FAILED: global timeout");
	$finish;
end

endmodule
