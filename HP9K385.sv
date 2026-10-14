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
//    SDRAM      main RAM at 0 (8/16/32 MB), boot ROM at ROM_BASE, 98550A card
//               ROM at CARD_BASE (both loaded at start-up)
//    DDR3       98550A VRAM at 0x3000_0000 (video) / 0x3020_0000 (overlay),
//               scanned out by the MiSTer framebuffer (8 bpp, stride 2048)
//    palette    the Nereid colormap, mirrored into the framebuffer palette
//    ROMs       games/HP9K385/boot0.rom  boot ROM 1818-5062 (MAME word order)
//                                boot1.rom  98550A ROM 98550a.bin
//                                boot2.rom  8042 firmware 1820-4784.bin
//    keyboard   PS/2 -> HP-HIL ITF keycodes -> the HIL loop
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
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 0;
assign AUDIO_L = 0;
assign AUDIO_R = 0;
assign AUDIO_MIX = 0;

assign LED_DISK = 0;
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
	"O[3:2],RAM,8 MB,16 MB,32 MB;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"v,0;",
	"V,v",`BUILD_DATE
};

wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;

wire        ioctl_download;
wire  [15:0] ioctl_index;
wire        ioctl_wr;
wire  [26:0] ioctl_addr;
wire  [15:0] ioctl_dout;
reg         ioctl_wait = 0;

hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.buttons(buttons),
	.status(status),
	.status_menumask(16'd0),

	.ps2_key(ps2_key),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait)
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

// boot0.rom (index 0) boot ROM, boot1.rom (0x40) card ROM, boot2.rom (0x80) 8042
localparam [26:2] ROM_BASE  = 25'h0FF_0000;     // byte 0x3FC_0000 (top 256 KB of 64 MB)
localparam [26:2] CARD_BASE = 25'h0FF_8000;     // byte 0x3FE_0000

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

// SDRAM writes for the boot and card ROMs.  ioctl words arrive with the
// file's first byte in [7:0]: the MAME boot ROM file is word-swapped, so its
// words are already the CPU's big-endian view; the card ROM is a plain byte
// stream and is swapped into big-endian lanes.
reg         ld_req;
reg  [26:2] ld_addr;
reg   [3:0] ld_be;
reg  [31:0] ld_wdata;
wire        sd_ack;

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
	if (ld_req && sd_ack) begin
		ld_req     <= 1'b0;
		ioctl_wait <= 1'b0;
	end
	if (ioctl_download && ioctl_wr) begin
		if (dl_hil) begin
			hil_wr <= 1'b1; hil_addr <= {ioctl_addr[10:1], 1'b0}; hil_data <= ioctl_dout[7:0];
			hil_hi <= ioctl_dout[15:8]; hil_second <= 1'b1;
		end
		else if (dl_boot || dl_card) begin
			ld_req     <= 1'b1;
			ioctl_wait <= 1'b1;
			ld_addr    <= (dl_boot ? ROM_BASE : CARD_BASE) + {8'd0, ioctl_addr[16:2]};
			ld_be      <= ioctl_addr[1] ? 4'b0011 : 4'b1100;
			ld_wdata   <= dl_boot ? {2{ioctl_dout}} : {2{ioctl_dout[7:0], ioctl_dout[15:8]}};
		end
	end
end

///////////////////////   MACHINE   //////////////////////////////

wire [11:0] ram_mask = status[3:2] == 2'd2 ? 12'hFE0 :     // 32 MB
                       status[3:2] == 2'd1 ? 12'hFF0 :     // 16 MB
                                             12'hFF8;      //  8 MB

wire        mem_req, mem_we;
wire  [1:0] mem_sel;
wire [31:2] mem_addr;
wire  [3:0] mem_be;
wire [31:0] mem_wdata;
wire [31:0] sd_rdata;

wire        vram_req, vram_we, vram_ack;
wire [21:2] vram_addr;
wire  [3:0] vram_be;
wire [31:0] vram_wdata, vram_rdata;
wire  [7:0] display_enable;
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

reg   [7:0] pal_idx;
wire [23:0] pal_rgb;

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
	.mem_ack(sd_ack && !ld_req),
	.mem_rdata(sd_rdata),

	.leds(leds),

	.hil_key_stb(key_stb),
	.hil_key_code(key_code),
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
	.display_enable(display_enable),
	.gfx_unsupported(),
	.pix_index(pal_idx),
	.pix_rgb(pal_rgb),

	.ev_stb(), .ev_kind(), .ev_addr(), .ev_be(), .ev_write(), .ev_data(), .ev_fc(), .ev_walker(),
	.cpu_halted(),
	.cpu_reset_out()
);

///////////////////////   SDRAM   ////////////////////////////////

// machine addresses -> SDRAM: RAM from 0, ROMs at the top
wire [26:2] m_sd_addr = mem_sel == 2'd0 ? ROM_BASE  + {10'd0, mem_addr[16:2]} :
                        mem_sel == 2'd2 ? CARD_BASE + {12'd0, mem_addr[14:2]} :
                                          {2'b00, mem_addr[24:2] & {~ram_mask[4:0], 18'h3FFFF}};

sdram_beat32 sdram
(
	.init(!pll_locked),
	.clk_sys(clk_sys),
	.clk_ram(clk_ram),

	.req(ld_req | mem_req),
	.we(ld_req ? 1'b1 : mem_we),
	.addr(ld_req ? ld_addr : m_sd_addr),
	.be(ld_req ? ld_be : mem_be),
	.wdata(ld_req ? ld_wdata : mem_wdata),
	.ack(sd_ack),
	.rdata(sd_rdata),
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

assign FB_EN          = 1'b1;
assign FB_FORMAT      = 5'b00011;               // 8 bpp, palette
assign FB_WIDTH       = 12'd1280;
assign FB_HEIGHT      = 12'd1024;
assign FB_BASE        = 32'h3000_0000;
assign FB_STRIDE      = 14'd2048;
assign FB_FORCE_BLANK = reset;

// Palette mirror: walk the 256 indices continuously; each lookup through
// the Nereid takes a clock, so write the previous index's colour.
reg [7:0] pal_idx_d;
always @(posedge clk_sys) begin
	pal_idx   <= pal_idx + 8'd1;
	pal_idx_d <= pal_idx;
end
assign FB_PAL_CLK  = clk_sys;
assign FB_PAL_ADDR = pal_idx_d;
assign FB_PAL_DOUT = pal_rgb;
assign FB_PAL_WR   = 1'b1;

// The core's own video output only carries a blank frame (the framebuffer
// drives HDMI): 1280 x 1024 timing at clk_sys / 1 is not needed, so a slow
// placeholder keeps the scaler's input defined.
reg  [10:0] hc;
reg  [9:0]  vc;
reg         ce_pix;
always @(posedge clk_sys) begin
	ce_pix <= ~ce_pix;
	if (ce_pix) begin
		hc <= (hc == 11'd799) ? 11'd0 : hc + 11'd1;
		if (hc == 11'd799) vc <= (vc == 10'd524) ? 10'd0 : vc + 10'd1;
	end
end
assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = ce_pix;
assign VGA_HS    = (hc >= 11'd656 && hc < 11'd752);
assign VGA_VS    = (vc >= 10'd490 && vc < 10'd492);
assign VGA_DE    = (hc < 11'd640 && vc < 10'd480);
assign {VGA_R, VGA_G, VGA_B} = 24'd0;

// Activity: the boot ROM's diagnostic LEDs are active low; light the user
// LED while any is lit after the self-test, and during ROM downloads.
assign LED_USER = ioctl_download | (leds != 8'hFF && leds != 8'h00);

endmodule
