// Unit bench for rtl/ps2_hil_keymap.sv (iverilog -g2012).
//   - letters, digits, punctuation, modifiers, Return, Esc, Tab, F1/F7/F9,
//     extended keys (arrows, Insert, Page Down, KP /, KP Enter, R Ctrl,
//     R Alt, R Win), keypad keys: make and break codes
//   - Print Screen as hps_io folds it ($37C / $17C)
//   - Pause as hps_io folds it ($377, make only): make + break on
//     consecutive clocks
//   - unmapped keys (Scroll Lock, Num Lock, E0 12 fake shift, F13-ish $08)
//     give no strobe; no strobe out of reset
//   - sweep of all 512 {E0, code} values: only Ctrl and the ISO 102nd key (= \ |) are deliberate
//     many-to-one mapping, and every make code is even
//
// Expected codes are hand-computed from MAME hlekbd.cpp itf_basic:
// COLn bit b -> ((n ^ 8) << 4) | (b << 1), | 1 on release.
`timescale 1ns/1ps
module tb_ps2_hil_keymap;
reg clk = 0, reset = 1;
always #5 clk = !clk;
reg  [10:0] ps2_key = 11'h000;
wire        key_stb;
wire  [7:0] key_code;
ps2_hil_keymap dut(.clk(clk), .reset(reset), .ps2_key(ps2_key),
	.key_stb(key_stb), .key_code(key_code));

integer errors = 0;

// strobe log
integer     nstb = 0;
reg   [7:0] stb_code [0:15];
integer     stb_cyc  [0:15];
integer     cyc = 0;
always @(posedge clk) begin
	cyc <= cyc + 1;
	if (key_stb) begin
		if (nstb < 16) begin stb_code[nstb] = key_code; stb_cyc[nstb] = cyc; end
		nstb = nstb + 1;
	end
end

// one hps_io event, then a few clocks to collect what comes out
task send(input ext, input [7:0] sc, input pressed);
	begin
		@(negedge clk);
		nstb = 0;
		ps2_key = {~ps2_key[10], pressed, ext, sc};
		repeat (4) @(posedge clk);
		#1;
	end
endtask

// expect exactly one strobe with this code
task key1(input [255:0] what, input ext, input [7:0] sc, input pressed, input [7:0] exp);
	begin
		send(ext, sc, pressed);
		if (nstb !== 1) begin
			$display("FAIL %0s: %0d strobes, expected 1", what, nstb); errors = errors + 1;
		end
		else if (stb_code[0] !== exp) begin
			$display("FAIL %0s: got %h expected %h", what, stb_code[0], exp); errors = errors + 1;
		end
	end
endtask

// press and release
task key(input [255:0] what, input ext, input [7:0] sc, input [7:0] make);
	begin
		key1(what, ext, sc, 1'b1, make);
		key1(what, ext, sc, 1'b0, make | 8'h01);
	end
endtask

task none(input [255:0] what, input ext, input [7:0] sc, input pressed);
	begin
		send(ext, sc, pressed);
		if (nstb !== 0) begin
			$display("FAIL %0s: %0d strobes (first %h), expected none", what, nstb, stb_code[0]);
			errors = errors + 1;
		end
	end
endtask

// sweep
reg   [7:0] seen [0:127];      // HIL code[7:1] -> {count}
reg   [8:0] first_of [0:127];  // first {E0, code} that produced it
integer     i, nmapped, ndup;
reg   [7:0] got;

initial begin
	// a pending toggle while in reset must not come out afterwards
	ps2_key = {1'b1, 1'b1, 1'b0, 8'h1C};
	repeat (4) @(posedge clk);
	nstb = 0;
	@(negedge clk); reset = 0;
	repeat (4) @(posedge clk); #1;
	if (nstb !== 0) begin $display("FAIL strobe out of reset"); errors = errors + 1; end

	// letters
	key("A",          0, 8'h1C, 8'h5A);   // COL13 bit 5: (13^8)=5 -> $50 | 5<<1
	key("Q",          0, 8'h15, 8'h6C);   // COL14 bit 6: $60 | $0C
	key("Z",          0, 8'h1A, 8'h38);   // COL11 bit 4: $30 | $08
	key("M",          0, 8'h3A, 8'hE0);   // COL6  bit 0: (6^8)=14 -> $E0
	key("I",          0, 8'h43, 8'hC0);   // COL4  bit 0: (4^8)=12 -> $C0
	key("N",          0, 8'h31, 8'hF0);   // COL7  bit 0: (7^8)=15 -> $F0

	// digits
	key("1",          0, 8'h16, 8'h7C);   // COL15 bit 6: (15^8)=7 -> $70 | $0C
	key("7",          0, 8'h3D, 8'h70);   // COL15 bit 0
	key("8",          0, 8'h3E, 8'hB0);   // COL3  bit 0: (3^8)=11 -> $B0
	key("0",          0, 8'h45, 8'hB4);   // COL3  bit 2: $B0 | $04

	// punctuation, space, control keys
	key("`",          0, 8'h0E, 8'h7E);   // COL15 bit 7
	key("/",          0, 8'h4A, 8'hE6);   // COL6  bit 3
	key("Space",      0, 8'h29, 8'hF2);   // COL7  bit 1
	key("Backspace",  0, 8'h66, 8'hBA);   // COL3  bit 5
	key("Tab",        0, 8'h0D, 8'h6E);   // COL14 bit 7
	key("Return",     0, 8'h5A, 8'hDA);   // COL5  bit 5: (5^8)=13 -> $D0 | $0A
	key("Esc",        0, 8'h76, 8'h3E);   // COL11 bit 7: DEL/Esc

	// modifiers
	key("L Shift",    0, 8'h12, 8'h0A);   // COL8  bit 5: (8^8)=0 -> $00 | $0A
	key("R Shift",    0, 8'h59, 8'h08);   // COL8  bit 4
	key("ISO 102nd",  0, 8'h61, 8'hCA);   // \ | as $5D (UK keyboards, remote typing)
	key("L Ctrl",     0, 8'h14, 8'h0C);   // COL8  bit 6: Control
	key("R Ctrl",     1, 8'h14, 8'h0C);   // COL8  bit 6: Control (E0 14)
	key("L Alt",      0, 8'h11, 8'h06);   // COL8  bit 3: Extend char L
	key("R Alt",      1, 8'h11, 8'h04);   // COL8  bit 2: Extend char R

	// shifted letter: Shift down, A down/up, Shift up
	key1("Sh+A sh",   0, 8'h12, 1, 8'h0A);
	key1("Sh+A a",    0, 8'h1C, 1, 8'h5A);
	key1("Sh+A a up", 0, 8'h1C, 0, 8'h5B);
	key1("Sh+A sh up",0, 8'h12, 0, 8'h0B);

	// function keys
	key("F1",         0, 8'h05, 8'h98);   // COL1  bit 4: (1^8)=9 -> $90 | $08
	key("F4",         0, 8'h0C, 8'h92);   // COL1  bit 1
	key("F7",         0, 8'h83, 8'hA6);   // COL2  bit 3: (2^8)=10 -> $A0 | $06
	key("F8",         0, 8'h0A, 8'hA8);   // COL2  bit 4
	key("F9 Menu",    0, 8'h01, 8'h90);   // COL1  bit 0: Menu
	key("F10 U/S",    0, 8'h09, 8'hA0);   // COL2  bit 0: User/System

	// extended cursor / editing keys
	key("Up",         1, 8'h75, 8'hFC);   // COL7  bit 6
	key("Left",       1, 8'h6B, 8'hF8);   // COL7  bit 4
	key("Right",      1, 8'h74, 8'hFE);   // COL7  bit 7
	key("Insert",     1, 8'h70, 8'hCC);   // COL4  bit 6: Insert char
	key("Page Down",  1, 8'h7A, 8'hEE);   // COL6  bit 7: Next
	key("R Win",      1, 8'h27, 8'h9C);   // COL1  bit 6: Stop

	// keypad: same scancodes as the cursor keys, without E0
	key("KP 8",       0, 8'h75, 8'h12);   // COL9  bit 1: (9^8)=1 -> $10 | $02
	key("KP 4",       0, 8'h6B, 8'h10);   // COL9  bit 0
	key("KP 5",       0, 8'h73, 8'h14);   // COL9  bit 2
	key("KP 7",       0, 8'h6C, 8'h1A);   // COL9  bit 5
	key("KP 0",       0, 8'h70, 8'h2C);   // COL10 bit 6: (10^8)=2 -> $20 | $0C
	key("KP 3",       0, 8'h7A, 8'h28);   // COL10 bit 4
	key("KP *",       0, 8'h7C, 8'h2A);   // COL10 bit 5
	key("KP .",       0, 8'h71, 8'h48);   // COL12 bit 4: (12^8)=4 -> $40 | $08
	key("KP /",       1, 8'h4A, 8'h22);   // COL10 bit 1 (E0 4A)
	key("KP Enter",   1, 8'h5A, 8'h1E);   // COL9  bit 7 (E0 5A)

	// Print Screen as hps_io reports it: $37C press, $17C release
	key("PrtSc",      1, 8'h7C, 8'h9E);   // COL1  bit 7: Print/Enter

	// Pause as hps_io reports it: $377, press only -> make then break
	send(1, 8'h77, 1);                     // COL8  bit 7: Break/Reset
	if (nstb !== 2 || stb_code[0] !== 8'h0E || stb_code[1] !== 8'h0F
	    || stb_cyc[1] !== stb_cyc[0] + 1) begin
		$display("FAIL Pause: %0d strobes %h %h", nstb, stb_code[0], stb_code[1]);
		errors = errors + 1;
	end
	key("after Pause",0, 8'h1C, 8'h5A);   // normal service resumes

	// Pause break and a new event in the same clock: the event is late, not lost
	@(negedge clk); nstb = 0;
	ps2_key = {~ps2_key[10], 1'b1, 1'b1, 8'h77};
	@(negedge clk);
	ps2_key = {~ps2_key[10], 1'b1, 1'b0, 8'h15};   // Q, while the break is due
	repeat (4) @(posedge clk); #1;
	if (nstb !== 3 || stb_code[0] !== 8'h0E || stb_code[1] !== 8'h0F || stb_code[2] !== 8'h6C) begin
		$display("FAIL Pause + Q: %0d strobes %h %h %h", nstb, stb_code[0], stb_code[1], stb_code[2]);
		errors = errors + 1;
	end
	key1("Q up",      0, 8'h15, 0, 8'h6D);

	// unmapped
	none("Scroll Lock", 0, 8'h7E, 1);
	none("Num Lock",    0, 8'h77, 1);
	none("Num Lock up", 0, 8'h77, 0);
	none("fake shift",  1, 8'h12, 1);
	none("$08",         0, 8'h08, 1);

	// sweep every {E0, code} as a press
	for (i = 0; i < 128; i = i + 1) seen[i] = 0;
	nmapped = 0; ndup = 0;
	for (i = 0; i < 512; i = i + 1) begin
		send(i[8], i[7:0], 1);
		if (i == 9'h177) begin
			if (nstb !== 2) begin $display("FAIL sweep Pause: %0d strobes", nstb); errors = errors + 1; end
		end
		else if (nstb > 1) begin
			$display("FAIL sweep %h: %0d strobes", i[8:0], nstb); errors = errors + 1;
		end
		if (nstb >= 1) begin
			got = stb_code[0];
			nmapped = nmapped + 1;
			if (got[0] !== 1'b0) begin
				$display("FAIL sweep %h: make code %h is odd", i[8:0], got); errors = errors + 1;
			end
			if (seen[got[7:1]] != 0) begin
				ndup = ndup + 1;
				if (got !== 8'h0C && got !== 8'hCA) begin
					$display("FAIL sweep %h: code %h already from %h", i[8:0], got, first_of[got[7:1]]);
					errors = errors + 1;
				end
			end
			else first_of[got[7:1]] = i[8:0];
			seen[got[7:1]] = seen[got[7:1]] + 1;
		end
	end
	if (ndup !== 2) begin $display("FAIL sweep: %0d duplicate codes, expected 2 (Ctrl, ISO 102nd)", ndup); errors = errors + 1; end
	$display("sweep: %0d PS/2 keys mapped", nmapped);

	if (errors == 0) $display("ALL TESTS PASSED");
	else $display("%0d ERRORS", errors);
	$finish;
end
endmodule
