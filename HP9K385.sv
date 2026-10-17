//============================================================================
//  HP9K385 — HP 9000 Model 385 for MiSTer.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  The machine is rtl/hp385_top.sv; this file is the MiSTer shell around it:
//    clocks     33.000 MHz clk_sys (CPU, devices), 99 MHz clk_ram (SDRAM)
//    SDRAM      main RAM at 0 (8/16/32/64/128 MB); boot ROM and 98550A card ROM
//               in block RAM (rtl/mem/rom_bram.sv), loaded at start-up
//    DDR3       98550A VRAM at 0x3000_0000 (video) / 0x3020_0000 (overlay),
//               8 bpp, stride 2048, read by rtl/scanout.sv (not the MiSTer
//               framebuffer: FB_EN is 0)
//    palette    the Nereid colormap, mirrored into the framebuffer palette
//    ROMs       games/HP9K385/boot0.rom  boot ROM 1818-5062 (MAME word order)
//                                boot1.rom  98550A ROM 98550a.bin
//                                boot2.rom  8042 firmware 1820-4784.bin
//    SCSI       98265A at select code 14: S0 / S1 disk images on IDs 0 / 1,
//               S2 CD-ROM on ID 2 (Main's support/hp9k translates CUE/CHD)
//    serial     98644 at select code 9 on MiSTer's UART (USER port)
//    keyboard   PS/2 -> HP-HIL ITF keycodes -> the HIL loop
//    mouse      PS/2 mouse -> HP 46060B on the HIL loop
//
//  Overlay planes are not composited by the framebuffer (docs/PLAN_385.md
//  §4, option A).
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S   = 1;              // signed: the keyboard beeper (SN76494)
assign AUDIO_MIX = 0;

assign LED_DISK = {1'b0, |sd_ack};
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

// 1280 x 1024 is 5:4
assign VIDEO_ARX = (!ar) ? 12'd5 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd4 : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"HP9K385;;",
	"-;",
	// "SC": Main_MiSTer remembers the image (config/HP9K385.s<n>) and
	// mounts it again at every core start
	"SC0,IMGHDVRAW,SCSI 0;",
	"SC1,IMGHDVRAW,SCSI 1;",
	"SC2,ISOCUECHD,CD-ROM (SCSI 2);",
	"-;",
	// index 0 of each option is its default (status 0 with no saved .CFG)
	"O[4:2],RAM,32 MB,64 MB,128 MB (128 MB SDRAM),8 MB,16 MB;",
	"O[5],Fast boot (no RAM test),Yes,No;",
	"-;",
	// LAN: the 98643A at select code 21; Main's hp9k_enet bridge carries its
	// frames (status 14:12 as on the HP 9000/715 core: 0 eth0, 1 Off, ...)
	"O[15],LAN card (98643A),Present,Absent;",
	"O[14:12],Network,eth0,Off,eth1,macvlan,tap0;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	// config version: 1 when RAM became 32 MB and Fast boot Yes by default;
	// Main drops a .CFG saved under another version
	"v,1;",
	"V,v",`BUILD_DATE
};

wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;
wire  [64:0] rtc;
wire  [24:0] ps2_mouse;

wire        ioctl_download;
wire  [15:0] ioctl_index;
wire        ioctl_wr;
wire  [26:0] ioctl_addr;
wire  [15:0] ioctl_dout;
reg         ioctl_wait = 0;

// SCSI: S0/S1 disks (IDs 0/1), S2 CD-ROM (ID 2)
wire  [2:0] img_mounted;
wire        img_readonly;
wire [63:0] img_size;
wire [31:0] sd_lba[3];
wire  [5:0] sd_blk_cnt[3];
wire  [2:0] sd_rd, sd_wr, sd_ack;
wire [12:0] sd_buff_addr;
wire [15:0] sd_buff_dout;
wire [15:0] sd_buff_din[3];
wire        sd_buff_wr;
wire [95:0] m_sd_lba;
wire [17:0] m_sd_blk_cnt;
wire [47:0] m_sd_buff_din;
assign sd_lba[0] = m_sd_lba[31:0];
assign sd_lba[1] = m_sd_lba[63:32];
assign sd_lba[2] = m_sd_lba[95:64];
assign sd_blk_cnt[0] = m_sd_blk_cnt[5:0];
assign sd_blk_cnt[1] = m_sd_blk_cnt[11:6];
assign sd_blk_cnt[2] = m_sd_blk_cnt[17:12];
assign sd_buff_din[0] = m_sd_buff_din[15:0];
assign sd_buff_din[1] = m_sd_buff_din[31:16];
assign sd_buff_din[2] = m_sd_buff_din[47:32];

hps_io #(.CONF_STR(CONF_STR), .WIDE(1), .VDNUM(3), .BLKSZ(2)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.buttons(buttons),
	.status(status),
	.status_menumask(16'd0),

	.ps2_key(ps2_key),
	.RTC(rtc),
	.ps2_mouse(ps2_mouse),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys, clk_ram, pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),       // 33.000 MHz
	.outclk_1(clk_ram),       // 99.000 MHz
	.locked(pll_locked)
);

///////////////////////   ROM LOADING   //////////////////////////

// boot0.rom (index 0) boot ROM, boot1.rom (0x40) card ROM, boot2.rom (0x80)
// 8042.  The boot and card ROMs live in block RAM (rom_bram), so all of the
// SDRAM is main RAM.

wire       dl_boot = ioctl_index[7:6] == 2'd0;
wire       dl_card = ioctl_index[7:6] == 2'd1;
wire       dl_hil  = ioctl_index[7:6] == 2'd2;

reg  [2:0] loaded = 0;
reg        dl_d;
always @(posedge clk_sys) begin
	dl_d <= ioctl_download;
	if (dl_d && !ioctl_download) begin
		if (dl_boot) loaded[0] <= 1'b1;
		if (dl_card) loaded[1] <= 1'b1;
		if (dl_hil)  loaded[2] <= 1'b1;
	end
end

wire reset = RESET | status[0] | buttons[1] | ioctl_download | !loaded[0] | !pll_locked;

// Boot and card ROM downloads.  ioctl words arrive with the file's first
// byte in [7:0]: the MAME boot ROM file is word-swapped, so its words are
// already the CPU's big-endian view; the card ROM is a plain byte stream and
// is swapped into big-endian lanes.  ioctl_addr[1] picks the longword half.
wire        rom_we  = ioctl_download && ioctl_wr && dl_boot;
wire        card_we = ioctl_download && ioctl_wr && dl_card;
wire        sdr_ack;                  // SDRAM beat acknowledge

// 8042 firmware: straight into its block RAM, a byte per clock
reg         hil_wr;
reg  [10:0] hil_addr;
reg   [7:0] hil_data, hil_hi;
reg         hil_second;

always @(posedge clk_sys) begin
	hil_wr <= 1'b0;
	if (hil_second) begin
		hil_wr <= 1'b1; hil_addr <= hil_addr + 11'd1; hil_data <= hil_hi; hil_second <= 1'b0;
	end
	if (ioctl_download && ioctl_wr && dl_hil) begin
		hil_wr <= 1'b1; hil_addr <= {ioctl_addr[10:1], 1'b0}; hil_data <= ioctl_dout[7:0];
		hil_hi <= ioctl_dout[15:8]; hil_second <= 1'b1;
	end
end

///////////////////////   MACHINE   //////////////////////////////

// RAM at the top of the address space, a power of two from 8 to 128 MB (the
// 128 MB setting needs a 128 MB SDRAM module: SDRAM address bit 26 is the
// second chip select).  OSD index: 0 32 MB (the default), 1 64 MB,
// 2 128 MB, 3 8 MB, 4 16 MB.  Latched while the machine is in reset, so a
// change in the OSD takes effect at the next reset, never under a running OS.
reg   [2:0] ram_sel = 3'd0;
always @(posedge clk_sys) if (reset) ram_sel <= status[4:2];
wire [11:0] ram_mask = ram_sel == 3'd2 ? 12'hF80 :     // 128 MB
                       ram_sel == 3'd1 ? 12'hFC0 :     //  64 MB
                       ram_sel == 3'd4 ? 12'hFF0 :     //  16 MB
                       ram_sel == 3'd3 ? 12'hFF8 :     //   8 MB
                                         12'hFE0;      //  32 MB

wire        mem_req, mem_we;
wire        mem_rom;                  // a boot / card ROM beat (block RAM, not SDRAM)
reg         rom_ack;
reg  [31:0] rom_rdata;
wire  [1:0] mem_sel;
wire [31:2] mem_addr;
wire  [3:0] mem_be;
wire [31:0] mem_wdata;
wire [31:0] sdr_rdata;

wire        vram_req, vram_we, vram_ack;
wire [21:2] vram_addr;
wire  [3:0] vram_be;
wire [31:0] vram_wdata, vram_rdata;
wire  [7:0] display_enable;
wire signed [15:0] beep;
assign AUDIO_L = beep;
assign AUDIO_R = beep;
wire  [7:0] leds;

wire        key_stb;
wire  [7:0] key_code;

ps2_hil_keymap keymap
(
	.clk(clk_sys),
	.reset(reset),
	.ps2_key(ps2_key),
	.key_stb(key_stb),
	.key_code(key_code)
);

// PS/2 mouse -> HIL: {toggle, Y, X, flags(yovf,xovf,ysign,xsign,1,m,r,l)}
reg         mouse_t;
always @(posedge clk_sys) mouse_t <= ps2_mouse[24];

// scanout <-> Nereid colormap lookup
wire  [7:0] so_video, so_overlay;
wire [23:0] so_rgb;

// LAN card <-> wire (see LAN (98643A) WIRE below)
wire        lan_tx_ready, lan_tx_we, lan_tx_send, lan_rx_avail, lan_rx_done, lan_padr_stb;
wire [10:0] lan_tx_addr, lan_tx_len, lan_rx_len, lan_rx_addr;
wire  [7:0] lan_tx_wdata, lan_rx_q;
wire [47:0] lan_padr;
wire        nb_req, nb_we, nb_ack;
wire [12:0] nb_addr;
wire [63:0] nb_wdata, nb_rdata;

hp385_top machine
(
	.clk(clk_sys),
	.reset(reset),
	.ce(1'b1),
	.ram_mask(ram_mask),

	.mem_req(mem_req),
	.mem_sel(mem_sel),
	.mem_we(mem_we),
	.mem_addr(mem_addr),
	.mem_be(mem_be),
	.mem_wdata(mem_wdata),
	.mem_ack(mem_rom ? rom_ack : sdr_ack),
	.mem_rdata(mem_rom ? rom_rdata : sdr_rdata),

	.leds(leds),

	.rtc_set(rtc),
	.hil_key_stb(key_stb),
	.hil_key_code(key_code),
	.hil_mouse_stb(mouse_t != ps2_mouse[24]),
	.hil_mouse_dx({ps2_mouse[4], ps2_mouse[15:8]}),
	.hil_mouse_dy({ps2_mouse[5], ps2_mouse[23:16]}),
	.hil_mouse_btn(ps2_mouse[2:0]),
	.img_mounted(img_mounted),
	.img_size(img_size),
	.img_readonly(img_readonly),
	.sd_lba(m_sd_lba),
	.sd_blk_cnt(m_sd_blk_cnt),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_wr(sd_buff_wr),
	.sd_buff_din(m_sd_buff_din),

	.uart_txd(UART_TXD),
	.uart_rxd(UART_RXD),
	.uart_rts_n(UART_RTS),
	.uart_dtr_n(UART_DTR),
	.uart_cts_n(UART_CTS),
	.uart_dsr_n(UART_DSR),
	.uart_dcd_n(1'b0),               // no DCD on the MiSTer port: carrier always present
	.uart_tx_stb(),
	.uart_tx_byte(),

	.hil_rom_wr(hil_wr),
	.hil_rom_addr(hil_addr),
	.hil_rom_data(hil_data),

	.vram_req(vram_req),
	.vram_we(vram_we),
	.vram_addr(vram_addr),
	.vram_be(vram_be),
	.vram_wdata(vram_wdata),
	.vram_ack(vram_ack),
	.vram_rdata(vram_rdata),
	.audio(beep),
	.display_enable(display_enable),
	.gfx_unsupported(),
	.pix_video(so_video),
	.pix_overlay(so_overlay),
	.pix_rgb(so_rgb),

	.lan_present(!status[15]),
	.lan_tx_ready(lan_tx_ready),
	.lan_tx_we(lan_tx_we),
	.lan_tx_addr(lan_tx_addr),
	.lan_tx_wdata(lan_tx_wdata),
	.lan_tx_send(lan_tx_send),
	.lan_tx_len(lan_tx_len),
	.lan_rx_avail(lan_rx_avail),
	.lan_rx_len(lan_rx_len),
	.lan_rx_addr(lan_rx_addr),
	.lan_rx_q(lan_rx_q),
	.lan_rx_done(lan_rx_done),
	.lan_padr(lan_padr),
	.lan_padr_stb(lan_padr_stb),

	.ev_stb(), .ev_kind(), .ev_addr(), .ev_be(), .ev_write(), .ev_data(), .ev_fc(), .ev_walker(),
	.cpu_halted(),
	.cpu_reset_out()
);

///////////////////////   SDRAM   ////////////////////////////////

// machine addresses -> SDRAM: RAM from 0 (mem_sel 1); the boot ROM
// (mem_sel 0, 128 KB) and the 98550A card ROM (mem_sel 2, 32 KB) are block RAM
assign      mem_rom   = (mem_sel != 2'd1);
wire [26:2] m_sd_addr = mem_addr[26:2] & {~ram_mask[6:0], 18'h3FFFF};

wire [31:0] boot_q, card_q;
rom_bram #(.AW(15)) boot_rom
(
	.clk(clk_sys),
	.we(rom_we), .waddr(ioctl_addr[16:2]), .whalf(ioctl_addr[1]), .wdata(ioctl_dout),
	.raddr(mem_addr[16:2]), .q(boot_q)
);
rom_bram #(.AW(13)) card_rom
(
	.clk(clk_sys),
	.we(card_we), .waddr(ioctl_addr[14:2]), .whalf(ioctl_addr[1]), .wdata({ioctl_dout[7:0], ioctl_dout[15:8]}),
	.raddr(mem_addr[14:2]), .q(card_q)
);

// Fast boot (OSD): the boot ROM as it is read, without the cold-boot RAM
// test (0x46A: 7A02 -> 7A00) and therefore without its checksum step (0x18F6:
// BSR checksum -> MOVEQ #0,D0 / NOP), as docs/disasm/tools/bootrom_simpatch.py
// does for the sim.  Each word is replaced only if it holds the expected
// original, so another ROM revision is left alone.
wire fast_boot = !status[5];               // OSD: Yes is index 0, the default
function [31:0] boot_patch;
	input [31:0] q;
	input [14:0] a;                           // longword address
	input        en;
	begin
		boot_patch = q;
		if (en) begin
			if (a == 15'h011A && q[15:0]  == 16'h7A02) boot_patch[15:0]  = 16'h7A00;
			if (a == 15'h063D && q[15:0]  == 16'h6100) boot_patch[15:0]  = 16'h7000;
			if (a == 15'h063E && q[31:16] == 16'h375A) boot_patch[31:16] = 16'h4E71;
		end
	end
endfunction

// ROM beats: the address is held with mem_req, so q is valid the clock after
// the request is seen; ack one clock after that (one pulse per request)
reg         rom_busy;
always @(posedge clk_sys) begin
	rom_ack <= 1'b0;
	if (reset) rom_busy <= 1'b0;
	else if (rom_busy) begin
		rom_busy  <= 1'b0;
		rom_ack   <= 1'b1;
		rom_rdata <= (mem_sel == 2'd0) ? boot_patch(boot_q, mem_addr[16:2], fast_boot) : card_q;
	end
	else if (mem_req && mem_rom && !rom_ack) rom_busy <= 1'b1;
end

sdram_beat32 sdram
(
	.init(!pll_locked),
	.clk_sys(clk_sys),
	.clk_ram(clk_ram),

	.req(mem_req && !mem_rom),
	.we(mem_we),
	.addr(m_sd_addr),
	.be(mem_be),
	.wdata(mem_wdata),
	.ack(sdr_ack),
	.rdata(sdr_rdata),
	.busy(),
	.line_valid_o(),
	.line_tag_o(),
	.line_data_o(),
	.line_pending_o(),
	.line_pending_tag_o(),

	.wp_valid(1'b0),
	.wp_addr(25'd0),
	.wp_be(4'd0),
	.wp_data(32'd0),
	.wq_room(),

	.SDRAM_DQ(SDRAM_DQ),
	.SDRAM_A(SDRAM_A),
	.SDRAM_DQML(SDRAM_DQML),
	.SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA),
	.SDRAM_nCS(SDRAM_nCS),
	.SDRAM_nWE(SDRAM_nWE),
	.SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_CKE(SDRAM_CKE),
	.SDRAM_CLK(SDRAM_CLK)
);

///////////////////////   LAN (98643A) WIRE   ///////////////////

// Frames to and from Main_MiSTer's hp9k_enet bridge through a DDR3 mailbox
// at ARM physical 0x1FF00000 (rtl/lan_wire.sv); the LANCE itself is in the
// core (rtl/lance.sv, rtl/hp98643.sv).

lan_wire #(.CLK_HZ(33_000_000)) lan_wire
(
	.clk(clk_sys),
	.reset(reset),
	.ena(status[14:12] != 3'd1),
	.mac(lan_padr),
	.mac_stb(lan_padr_stb),
	.tx_ready(lan_tx_ready),
	.tx_we(lan_tx_we),
	.tx_addr(lan_tx_addr),
	.tx_wdata(lan_tx_wdata),
	.tx_send(lan_tx_send),
	.tx_len(lan_tx_len),
	.rx_avail(lan_rx_avail),
	.rx_len(lan_rx_len),
	.rx_addr(lan_rx_addr),
	.rx_q(lan_rx_q),
	.rx_done(lan_rx_done),
	.nb_req(nb_req),
	.nb_we(nb_we),
	.nb_addr(nb_addr),
	.nb_wdata(nb_wdata),
	.nb_ack(nb_ack),
	.nb_rdata(nb_rdata)
);

///////////////////////   VRAM (DDR3) AND VIDEO   ////////////////

assign DDRAM_CLK = clk_sys;

vram_ddr3 #(.BASE(29'h0600_0000)) vram
(
	.clk(clk_sys),
	.reset(!pll_locked),
	.req(vram_req),
	.we(vram_we),
	.addr(vram_addr),
	.be(vram_be),
	.wdata(vram_wdata),
	.ack(vram_ack),
	.rdata(vram_rdata),
	.f_req(f_req),
	.f_addr(f_addr),
	.f_ack(f_ack),
	.f_valid(f_valid),
	.f_data(f_data),
	.nb_req(nb_req),
	.nb_we(nb_we),
	.nb_addr(nb_addr),
	.nb_wdata(nb_wdata),
	.nb_ack(nb_ack),
	.nb_rdata(nb_rdata),
	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BE(DDRAM_BE),
	.DDRAM_WE(DDRAM_WE)
);

// The 98550A display: both VRAM banks scanned out of DDR3 by the core
// (rtl/scanout.sv), overlay over video through the Nereid colormaps; the
// MiSTer framebuffer is off (it can show only one 8-bit buffer, and HP's
// X server draws the pointer in the overlay bank).
wire        f_req, f_ack, f_valid;
wire [28:0] f_addr;
wire [63:0] f_data;
wire        so_hs, so_vs, so_de;
wire [23:0] so_pix;

scanout #(.BASE(29'h0600_0000), .OVL(29'h0604_0000)) scan
(
	.clk(clk_sys),
	.reset(!pll_locked),
	.f_req(f_req),
	.f_addr(f_addr),
	.f_ack(f_ack),
	.f_valid(f_valid),
	.f_data(f_data),
	.pix_video(so_video),
	.pix_overlay(so_overlay),
	.pix_rgb(so_rgb),
	.hs(so_hs),
	.vs(so_vs),
	.de(so_de),
	.rgb(so_pix)
);

assign FB_EN          = 1'b0;
assign FB_FORMAT      = 5'b00011;
assign FB_WIDTH       = 12'd1280;
assign FB_HEIGHT      = 12'd1024;
assign FB_BASE        = 32'h3000_0000;
assign FB_STRIDE      = 14'd2048;
assign FB_FORCE_BLANK = 1'b0;
assign FB_PAL_CLK     = clk_sys;
assign FB_PAL_ADDR    = 8'd0;
assign FB_PAL_DOUT    = 24'd0;
assign FB_PAL_WR      = 1'b0;

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = 1'b1;
assign VGA_HS    = so_hs;
assign VGA_VS    = so_vs;
assign VGA_DE    = so_de;
assign {VGA_R, VGA_G, VGA_B} = so_pix;

// Activity: the boot ROM's diagnostic LEDs are active low; light the user
// LED while any is lit after the self-test, and during ROM downloads.
assign LED_USER = ioctl_download | (leds != 8'hFF && leds != 8'h00);

endmodule
