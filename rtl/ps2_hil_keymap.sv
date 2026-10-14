//============================================================================
//  ps2_hil_keymap — MiSTer PS/2 key events to HP-HIL ITF (HP 46021A)
//  keycodes, for the hil_card keyboard queue (kbd_stb / kbd_code).
//
//  Input: hps_io ps2_key[10:0] = {toggle, pressed, extended (E0), Set 2
//  scancode}.  Every event flips bit 10.  hps_io folds two multi-byte
//  sequences into single events: Print Screen arrives as E0 7C (make and
//  break), and Pause arrives as E0 77 *make only* (Main_MiSTer sends the
//  whole E1 14 77 E1 F0 14 F0 77 burst when the key is let go, and hps_io
//  reports it as pressed).  Pause therefore produces the Break/Reset make
//  and, on the next clock, its break.
//
//  Output: HIL keycode, ITF layout as MAME hlekbd.cpp itf_basic models it.
//  Port COLn bit b is keycode ((n ^ 8) << 4) | (b << 1) on make, | 1 on
//  break (key_make()/key_break(): ((row + 1) ^ 8) << 4 + (column << 1)).
//  So COL1 = $90-$9E ... COL7 = $F0-$FE, COL8 = $00-$0E ... COL15 = $70-$7E.
//  Cross-checked against the Linux hilkbd table (HIL_KEYCODES_SET1 in
//  include/linux/hil.h, indexed by keycode >> 1); NetBSD's hilkbdmap is not
//  available locally.
//
//  The table is a case on {extended, scancode} giving {valid, code[7:1]};
//  unmapped keys give no strobe.  key_stb is a one-clock pulse.  ps2_key must
//  be in the clk domain (it is held between events, so a 2-flop resync of the
//  whole bus is also fine as long as bit 10 is the last bit to settle).
//
//  Keys that match directly (PC key -> ITF key, keycode):
//    A-Z, 0-9, ` - = [ ] \ ; ' , . /, Space, Backspace $BA, Tab $6E,
//    Return $DA, Esc -> DEL/Esc $3E, Caps Lock $5E, L Shift $0A,
//    R Shift $08, L Ctrl and R Ctrl -> Control $0C (the ITF has one),
//    L Alt -> Extend char L $06, R Alt -> Extend char R $04,
//    F1-F8 -> f1-f8 ($98 $96 $94 $92 $A2 $A4 $A6 $A8),
//    arrows ($F8 left, $FA down, $FC up, $FE right),
//    Insert -> Insert char $CC, Delete -> Delete char $CE, Home $DC,
//    Page Up -> Prev $DE, Page Down -> Next $EE,
//    keypad 0-9, / * - + Enter, and . -> KP . $48 (COL12 bit 4: an unnamed
//    key in MAME, KEY_KPDOT in Linux).  KP 5 -> $14 (COL9 bit 2); MAME also
//    names COL8 bit 0 ($00) "KP 5", Linux calls $00 KEY_5 -- left unmapped.
//
//  HP keys with no PC counterpart, placed on spare PC keys:
//    PC key          ITF key          code  why
//    Pause/Break     Break/Reset      $0E   same name (make + break, see above)
//    Print Screen    Print/Enter      $9E   same name
//    R Win           Stop             $9C   MAME's PORT_CODE (KEYCODE_RWIN)
//    F9              Menu             $90   MAME's PORT_CODE (KEYCODE_F9)
//    F10             User/System      $A0   MAME's PORT_CODE (KEYCODE_F10)
//    F11             Clear line       $AC   next along the top row, as on
//    F12             Clear display    $AE   the ITF (f8, Clear line, Clear
//                                           display); F12 only reaches the
//                                           core if MiSTer's OSD key is moved
//    End             Select           $EA   six-key block: Ins/Home/PgUp =
//                                           Insert char/Home/Prev, Del/End/
//                                           PgDn = Delete char/Select/Next
//    L Win           Insert line      $BC   free key
//    Menu (Apps)     Delete line      $BE   free key
//
//  ITF keys left unmapped: KP , ($1C), KP Tab ($4C), the four blank keys
//  above the keypad (MAME/Linux "F9-F12": $4A $42 $46 $4E; PC F9/F10 are
//  given to Menu and User/System instead, which MAME also binds to them),
//  and $00 (see KP 5).  Num Lock and Scroll Lock are not used: Main_MiSTer
//  swallows their make for joystick/mouse emulation and passes only the
//  break, which would arrive here as a lone release.  The ISO 102nd key
//  ($61) is not mapped either (Linux puts KEY_102ND at $EC, MAME has it
//  unused).
//============================================================================

module ps2_hil_keymap (
	input            clk,
	input            reset,
	input     [10:0] ps2_key,       // MiSTer hps_io format
	output reg       key_stb,       // one-clock pulse per translated event
	output reg [7:0] key_code       // HIL keycode, bit 0 = 1 for release
);

// {valid, code[7:1]} from a make code written out in full
/* verilator lint_off UNUSEDSIGNAL */
function automatic [7:0] hk(input [7:0] make);
	hk = {1'b1, make[7:1]};
endfunction
/* verilator lint_on UNUSEDSIGNAL */

// ---- translation table: {E0, Set 2 scancode} -> {valid, code[7:1]} ----
reg  [7:0] ent;
always @(*) begin
	case ({ps2_key[8], ps2_key[7:0]})
	// letters
	9'h01C: ent = hk(8'h5A);    // A          COL13.5
	9'h032: ent = hk(8'h30);    // B          COL11.0
	9'h021: ent = hk(8'h34);    // C          COL11.2
	9'h023: ent = hk(8'h56);    // D          COL13.3
	9'h024: ent = hk(8'h68);    // E          COL14.4
	9'h02B: ent = hk(8'h54);    // F          COL13.2
	9'h034: ent = hk(8'h52);    // G          COL13.1
	9'h033: ent = hk(8'h50);    // H          COL13.0
	9'h043: ent = hk(8'hC0);    // I          COL4.0
	9'h03B: ent = hk(8'hD0);    // J          COL5.0
	9'h042: ent = hk(8'hD2);    // K          COL5.1
	9'h04B: ent = hk(8'hD4);    // L          COL5.2
	9'h03A: ent = hk(8'hE0);    // M          COL6.0
	9'h031: ent = hk(8'hF0);    // N          COL7.0
	9'h044: ent = hk(8'hC2);    // O          COL4.1
	9'h04D: ent = hk(8'hC4);    // P          COL4.2
	9'h015: ent = hk(8'h6C);    // Q          COL14.6
	9'h02D: ent = hk(8'h66);    // R          COL14.3
	9'h01B: ent = hk(8'h58);    // S          COL13.4
	9'h02C: ent = hk(8'h64);    // T          COL14.2
	9'h03C: ent = hk(8'h60);    // U          COL14.0
	9'h02A: ent = hk(8'h32);    // V          COL11.1
	9'h01D: ent = hk(8'h6A);    // W          COL14.5
	9'h022: ent = hk(8'h36);    // X          COL11.3
	9'h035: ent = hk(8'h62);    // Y          COL14.1
	9'h01A: ent = hk(8'h38);    // Z          COL11.4

	// digit row
	9'h016: ent = hk(8'h7C);    // 1          COL15.6
	9'h01E: ent = hk(8'h7A);    // 2          COL15.5
	9'h026: ent = hk(8'h78);    // 3          COL15.4
	9'h025: ent = hk(8'h76);    // 4          COL15.3
	9'h02E: ent = hk(8'h74);    // 5          COL15.2
	9'h036: ent = hk(8'h72);    // 6          COL15.1
	9'h03D: ent = hk(8'h70);    // 7          COL15.0
	9'h03E: ent = hk(8'hB0);    // 8          COL3.0
	9'h046: ent = hk(8'hB2);    // 9          COL3.1
	9'h045: ent = hk(8'hB4);    // 0          COL3.2

	// punctuation
	9'h00E: ent = hk(8'h7E);    // ` ~        COL15.7
	9'h04E: ent = hk(8'hB6);    // - _        COL3.3
	9'h055: ent = hk(8'hB8);    // = +        COL3.4
	9'h054: ent = hk(8'hC6);    // [ {        COL4.3
	9'h05B: ent = hk(8'hC8);    // ] }        COL4.4
	9'h05D: ent = hk(8'hCA);    // \ |        COL4.5
	9'h04C: ent = hk(8'hD6);    // ; :        COL5.3
	9'h052: ent = hk(8'hD8);    // ' "        COL5.4
	9'h041: ent = hk(8'hE2);    // , <        COL6.1
	9'h049: ent = hk(8'hE4);    // . >        COL6.2
	9'h04A: ent = hk(8'hE6);    // / ?        COL6.3
	9'h029: ent = hk(8'hF2);    // Space      COL7.1

	// control and modifier keys
	9'h066: ent = hk(8'hBA);    // Backspace  COL3.5
	9'h00D: ent = hk(8'h6E);    // Tab        COL14.7
	9'h05A: ent = hk(8'hDA);    // Enter      COL5.5  Return
	9'h076: ent = hk(8'h3E);    // Esc        COL11.7 DEL/Esc
	9'h058: ent = hk(8'h5E);    // Caps Lock  COL13.7
	9'h012: ent = hk(8'h0A);    // L Shift    COL8.5
	9'h059: ent = hk(8'h08);    // R Shift    COL8.4
	9'h014: ent = hk(8'h0C);    // L Ctrl     COL8.6  Control
	9'h114: ent = hk(8'h0C);    // R Ctrl     COL8.6  Control
	9'h011: ent = hk(8'h06);    // L Alt      COL8.3  Extend char L
	9'h111: ent = hk(8'h04);    // R Alt      COL8.2  Extend char R

	// function row
	9'h005: ent = hk(8'h98);    // F1         COL1.4  f1
	9'h006: ent = hk(8'h96);    // F2         COL1.3  f2
	9'h004: ent = hk(8'h94);    // F3         COL1.2  f3
	9'h00C: ent = hk(8'h92);    // F4         COL1.1  f4
	9'h003: ent = hk(8'hA2);    // F5         COL2.1  f5
	9'h00B: ent = hk(8'hA4);    // F6         COL2.2  f6
	9'h083: ent = hk(8'hA6);    // F7         COL2.3  f7
	9'h00A: ent = hk(8'hA8);    // F8         COL2.4  f8
	9'h001: ent = hk(8'h90);    // F9         COL1.0  Menu
	9'h009: ent = hk(8'hA0);    // F10        COL2.0  User/System
	9'h078: ent = hk(8'hAC);    // F11        COL2.6  Clear line
	9'h007: ent = hk(8'hAE);    // F12        COL2.7  Clear display

	// editing and cursor keys (all E0)
	9'h170: ent = hk(8'hCC);    // Insert     COL4.6  Insert char
	9'h171: ent = hk(8'hCE);    // Delete     COL4.7  Delete char
	9'h16C: ent = hk(8'hDC);    // Home       COL5.6
	9'h17D: ent = hk(8'hDE);    // Page Up    COL5.7  Prev
	9'h17A: ent = hk(8'hEE);    // Page Down  COL6.7  Next
	9'h169: ent = hk(8'hEA);    // End        COL6.5  Select
	9'h16B: ent = hk(8'hF8);    // Left       COL7.4
	9'h172: ent = hk(8'hFA);    // Down       COL7.5
	9'h175: ent = hk(8'hFC);    // Up         COL7.6
	9'h174: ent = hk(8'hFE);    // Right      COL7.7

	// numeric keypad
	9'h070: ent = hk(8'h2C);    // KP 0       COL10.6
	9'h069: ent = hk(8'h20);    // KP 1       COL10.0
	9'h072: ent = hk(8'h24);    // KP 2       COL10.2
	9'h07A: ent = hk(8'h28);    // KP 3       COL10.4
	9'h06B: ent = hk(8'h10);    // KP 4       COL9.0
	9'h073: ent = hk(8'h14);    // KP 5       COL9.2
	9'h074: ent = hk(8'h18);    // KP 6       COL9.4
	9'h06C: ent = hk(8'h1A);    // KP 7       COL9.5
	9'h075: ent = hk(8'h12);    // KP 8       COL9.1
	9'h07D: ent = hk(8'h16);    // KP 9       COL9.3
	9'h071: ent = hk(8'h48);    // KP .       COL12.4
	9'h14A: ent = hk(8'h22);    // KP /       COL10.1
	9'h07C: ent = hk(8'h2A);    // KP *       COL10.5
	9'h07B: ent = hk(8'h2E);    // KP -       COL10.7
	9'h079: ent = hk(8'h26);    // KP +       COL10.3
	9'h15A: ent = hk(8'h1E);    // KP Enter   COL9.7

	// HP keys on spare PC keys (see the header)
	9'h177: ent = hk(8'h0E);    // Pause      COL8.7  Break/Reset
	9'h17C: ent = hk(8'h9E);    // Print Scr  COL1.7  Print/Enter
	9'h127: ent = hk(8'h9C);    // R Win      COL1.6  Stop
	9'h11F: ent = hk(8'hBC);    // L Win      COL3.6  Insert line
	9'h12F: ent = hk(8'hBE);    // Apps       COL3.7  Delete line

	default: ent = 8'h00;
	endcase
end

// hps_io never reports a Pause release: add the break ourselves
wire       is_pause = ps2_key[8] && ps2_key[7:0] == 8'h77 && ps2_key[9];

// ---- event detect and output register ----
reg        tog_seen;          // ps2_key[10] at the last event taken
reg        brk_pend;          // Pause break due next clock

always @(posedge clk) begin
	key_stb <= 1'b0;
	if (reset) begin
		tog_seen <= ps2_key[10];   // no event for whatever is latched now
		brk_pend <= 1'b0;
		key_code <= 8'h00;
	end
	else if (brk_pend) begin
		// a new toggle in this clock is left for the next one: tog_seen
		// still differs, and ps2_key holds until the following event
		brk_pend <= 1'b0;
		key_stb  <= 1'b1;
		key_code <= {key_code[7:1], 1'b1};
	end
	else if (ps2_key[10] != tog_seen) begin
		tog_seen <= ps2_key[10];
		if (ent[7]) begin
			key_stb  <= 1'b1;
			key_code <= {ent[6:0], ~ps2_key[9]};
			brk_pend <= is_pause;
		end
	end
end

endmodule
