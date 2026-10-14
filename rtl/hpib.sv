//============================================================================
//  hpib — built-in HP-IB of the HP 300 human-interface card: card registers
//  plus a *reduced* TMS9914 for a system controller alone on the bus.
//  Wiring from MAME bus/hp_dio/human_interface.cpp; register behaviour from
//  MAME machine/tms9914.cpp, cut down to the states that exist with no other
//  device on the bus:
//    controller   IDLE -> (sic) ACTIVE (ATN) <-> (gts / tca,tcs) STANDBY,
//                 rlc / swrst -> IDLE
//    talker       TIDS / TADS (ton, or talk addressed); TACS = TADS && !ATN
//    listener     LIDS / LADS (lon); addressing one side unaddresses the other
//    remote/local LOCS -> REMS on listen-address with REN and !rtl (RLC)
//  BO is raised when the source handshake becomes able to send (TACS or
//  controller active) and cleared by a data-out write; interrupt status
//  registers clear on read.  Bytes written with nobody listening go nowhere.
//  Phase 2 replaces this with a full port for CS/80 disks.
//
//  Host map (odd bytes, mirrored over $47xxxx; the boot ROM uses $478000):
//    +1  ID $80 / write: card reset       +3  int ctl: 7 =1, 6 IRQ, 0 DMA en
//    +5  status: $81 | !CIC<<6 | KBDNMI<<2 +7  parallel-poll ctl  +9  ppoll mask
//    +$11..+$1F  TMS9914 registers 0-7
//      read : 0 INT0  1 INT1  2 address status  3 bus status  6 cmd pt  7 data in
//      write: 0 MASK0 1 MASK1 3 aux command 4 address 5 serial poll 6 ppoll 7 data
//============================================================================

module hpib
(
	input             clk,
	input             reset,

	input             cs,
	input             we,
	input       [4:0] addr,            // byte offset within the 32-byte block
	input       [7:0] din,
	output reg  [7:0] dout,

	input             kbd_nmi,
	output            irq,             // IRQ 3
	output            card_reset       // write to +1: resets the whole human interface
);

assign card_reset = cs && we && !addr[4] && addr[3:1] == 3'd0;

localparam C_IDLE = 2'd0, C_ACTIVE = 2'd1, C_STANDBY = 2'd2;

reg  [1:0] c_state;
reg        swrst, sic, sre, rtl, dai;
reg        tads, lads, rem;
reg  [7:0] int0, int1, mask0, mask1, address, data_in;
reg        dma_en;
reg  [7:0] ppoll_sc, ppoll_mask;
reg        can_source_q;

wire atn        = (c_state == C_ACTIVE);
wire cic        = (c_state != C_IDLE);
wire can_source = (tads && !atn) || (c_state == C_ACTIVE);
wire int_line   = !dai && (|(int0[5:0] & mask0[5:0]) || |(int1 & mask1));
assign irq = int_line;

wire [7:0] addr_stat = {rem, 1'b0, atn, 2'b00, lads, tads, 1'b0};
wire [7:0] bus_stat  = {atn, 5'b00000, sic, sre};
wire [7:0] int0_rd   = {|(int0[5:0] & mask0[5:0]), |(int1 & mask1), int0[5:0]};

always @(*) begin
	dout = 8'hFF;
	if (addr[4]) begin
		case (addr[3:1])
		3'd0: dout = int0_rd;
		3'd1: dout = int1;
		3'd2: dout = addr_stat;
		3'd3: dout = bus_stat;
		3'd6: dout = 8'h00;
		3'd7: dout = data_in;
		default: dout = 8'hFF;
		endcase
	end
	else case (addr[3:1])
	3'd0: dout = 8'h80;
	3'd1: dout = {1'b1, int_line, 5'b0, dma_en};
	3'd2: dout = {1'b1, !cic, 3'b000, kbd_nmi, 1'b0, 1'b1};
	3'd3: dout = ppoll_sc;
	3'd4: dout = ppoll_mask;
	default: dout = 8'hFF;
	endcase
end

// listen / talk address functions (MAME do_LAF / do_TAF)
task automatic laf;
	begin
		lads <= 1'b1; tads <= 1'b0;
		if (!rem && !rtl && sre) begin rem <= 1'b1; int0[1] <= 1'b1; end
	end
endtask

wire listener_reset = swrst || address[5] || sic;
wire talker_reset   = swrst || address[6] || sic;

always @(posedge clk) begin
	if (reset || card_reset) begin
		c_state <= C_IDLE; swrst <= 1'b1; sic <= 0; sre <= 0; rtl <= 0; dai <= 0;
		tads <= 0; lads <= 0; rem <= 0; int0 <= 0; int1 <= 0; mask0 <= 0; mask1 <= 0;
		address <= 0; data_in <= 0; dma_en <= 0; ppoll_sc <= 0; ppoll_mask <= 0;
		can_source_q <= 0;
	end
	else begin
		// BO when the source handshake becomes able to send
		can_source_q <= can_source;
		if (can_source && !can_source_q) int0[4] <= 1'b1;
		// REN dropped: back to local
		if (!sre && rem) begin rem <= 1'b0; int0[1] <= 1'b1; end

		if (cs && !we && addr[4]) begin
			if (addr[3:1] == 3'd0) int0 <= 8'h00;
			if (addr[3:1] == 3'd1) int1 <= 8'h00;
		end

		if (cs && we) begin
			if (addr[4]) case (addr[3:1])
			3'd0: mask0 <= din;
			3'd1: mask1 <= din;
			3'd4: address <= din;
			3'd7: int0[4] <= 1'b0;                      // data out: nobody listens
			3'd3: begin                                   // auxiliary command
				case (din[4:0])
				5'h00: begin                              // swrst
					if (din[7] && !swrst) begin
						int0 <= 0; int1 <= 0; tads <= 0; lads <= 0; rem <= 0;
						c_state <= C_IDLE;
					end
					swrst <= din[7];
				end
				5'h07: begin rtl <= din[7]; if (din[7] && rem) begin rem <= 1'b0; int0[1] <= 1'b1; end end
				5'h09: if (din[7]) begin if (!listener_reset) laf; end else lads <= 1'b0;   // lon
				5'h0A: if (din[7]) begin if (!talker_reset) begin tads <= 1'b1; lads <= 1'b0; end end
				       else tads <= 1'b0;                                                    // ton
				5'h0B: if (c_state == C_ACTIVE) c_state <= C_STANDBY;                        // gts
				5'h0C, 5'h0D: if (c_state == C_STANDBY) c_state <= C_ACTIVE;                 // tca, tcs
				5'h0F: begin                                                                  // sic
					sic <= din[7];
					if (din[7]) begin
						tads <= 1'b0; lads <= 1'b0;       // IFC unaddresses everyone
						if (!swrst && c_state == C_IDLE) c_state <= C_ACTIVE;
					end
				end
				5'h10: sre <= din[7];                                                         // sre
				5'h11: if (!swrst && c_state == C_IDLE) c_state <= C_ACTIVE;                 // rqc
				5'h12: c_state <= C_IDLE;                                                     // rlc
				5'h13: dai <= din[7];                                                         // dai
				default: ;
				endcase
			end
			default: ;
			endcase
			else case (addr[3:1])
			3'd1: dma_en <= din[0];
			3'd3: ppoll_sc <= din & 8'h80;
			3'd4: ppoll_mask <= din;
			default: ;
			endcase
		end
	end
end

endmodule
