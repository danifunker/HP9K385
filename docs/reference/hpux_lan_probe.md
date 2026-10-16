# HP-UX 9.10 and the 98643A LAN card: why "BAD/MISSING LAN HARDWARE @ SEL CODE 21"

Source: `scratch/hpux/hp-ux.lst` (kernel text). Addresses are kernel text addresses.
The HP compiler pads branch targets to a long boundary with `0000`, which desyncs the linear
`kdis.py all` listing in places. Re-disassemble at the branch target (`kdis.py ADDR ADDR2`).
Headers: `scratch/hpux/conf/machine/drvhw.h` (the `hw_globals` layout, card states) and `conf/h/io.h` (`isc_table_type`).

**Result.** The card fails the driver's built-in self-test, in `_hw_int_test`, at **error 26 ($1A): the NOVRAM read/write test**.
- The kernel writes test patterns into the NOVRAM window (`+$C000-$C07F`) and reads them back.
- `rtl/hp98643.sv` ignores NOVRAM writes, so the readback compare fails.
- Every other check that `drv_init` makes (ID, interrupt level, NOVRAM checksum, registers, RAM, the six LANCE loopback tests, the external loopback, `hw_startup`) passes against the current RTL. That was checked by hand, instruction by instruction.

## 1. Call chain and where the message comes from

`_lanift_init` ($18c2e):
1. kmallocs the ift and globals.
2. Calls `_lanc_attach` (`if_attach` only, no hardware access).
3. Calls `_drv_init(glob+$14a, sc=isc->my_isc, 0)`. Then it calls `_lanc_init(ift)`.
4. If either one returns non-zero, it prints the message at $18fd0.

`_lanc_init` ($1c636) always returns 0. However, it calls `drv_hw_req(ift, 2, 0)`, which is `drv_restart(glob, 0)` ($19730). **So the whole self-test and start-up run a second time.**

`_drv_init` ($186d2). A5 = `hw_globals` = glob + $e:
1. `_hw_reset_card(glob, sc)`. On failure it logs and calls `drv_lan_dead`, but **continues**.
2. `_hw_read_local_address(hw, glob+$6)`. On failure it returns that error.
3. If step 1 failed, it returns that error (`$80`).
4. `_drv_restart(glob, $64)`. This runs at **spl6**:
   - `_hw_self_test`, which is `_hw_int_test` followed by `_hw_ext_test`.
   - On success, `_hw_startup`.
   - On any failure it returns `$cc`, and so `drv_init` returns `$cc`.

Card window offsets: base = isc `card_ptr` = `$20400000 + sc<<16`, the kernel's mapping of the DIO space.

| Offset | Use |
|---|---|
| +1 | ID |
| +3 | status/control |
| +$4000 | RDP |
| +$4002 | RAP |
| +$8000 | card RAM; the init block is at RAM+0 |
| +$C000 | NOVRAM |

## 2. What each step does, compared with the RTL

### 2.1 `_hw_reset_card` ($1b66e): passes

Checks:
- isc `card_type` is 15. `lan_make_entry` ($1fa78) sets it when the ID is $15.
- isc `int_lvl` is 5. `kernel_initialize` ($a983c) sets it from status bits 5:4 plus 3.
- `(+1) & $7F == $15`, otherwise panic.
- `((+3)>>4)&3 == 2`, otherwise panic.

Then it calls `isrlink(hw_isr, level 5, +3, mask $c0, $c0)`. It also lays out the RAM pointers:

| Region | Offset in RAM |
|---|---|
| init block | 0 |
| receive ring | $18-$117 (32 descriptors) |
| transmit ring | $118-$197 (16 descriptors) |
| receive buffers | $198-$2797 (32 × 304 bytes, chained) |
| transmit area | $2798-$3FFF |

It makes no card writes. The RTL matches: ID $0015, bits 5:4 = 2, and the remote bit is not tested because it is masked off.

### 2.2 `_hw_read_local_address` ($1bbda): passes

1. Reads byte 0 from `+$C001`/`+$C003` (low nibble of each). If bit 0 is set, it uses the copy at +$40.
2. Sums bytes 0 and 1.
3. Reads bytes 2-7 as the MAC, adding them to the sum.
4. Adds bytes 8-14.
5. Compares the sum's low byte with byte 15.

On a mismatch it sets card_state 3, writes $01 to +1 (card reset) and $00 to +3, and returns $cc. The RTL image matches, because byte 0 is 0 and so sum(0..14) = sum(1..14).

### 2.3 `_hw_int_test` ($1be90, hand-written assembly at $1bf1c)

Error codes are D7, which becomes `card_state`. On any failure it:
- restores NOVRAM from the save area,
- writes $01 to +1,
- makes `hw_self_test` return $cc.

| D7 | Kernel | Action / expectation | RTL |
|---|---|---|---|
| – | $1bf1c | Save NOVRAM `+$C000-$C07F` (32 long reads) to $1146a8 | ok |
| 11 | $1bfb8 | Write $00 to +3. Expect `(+3) & $88 == 0` (IE, LOCK) | ok |
| 12 | $1bfcc | Write $08 to +3. Expect LOCK to read back set | ok |
| 13 / 44 | $1c31e | Up to 10 tries: RAP←0, wait for +3 bit 2 (ACK). Then CSR0←$0004 (STOP). Expect CSR0 == $0004 | ok (any LANCE access sets ACK) |
| 14 | $1bfee | Expect `(+3) & $0C == $0C` (LOCK and ACK) | ok |
| 15 | $1c000 | Expect CSR0 == 4. Then CSR0←$0002 (STRT without INIT) | ok. The RTL starts with MODE 0 and stale TDRA/RDRA until the reset below. Harmless. |
| 16/17 | $1c2ee | Clear all 64 NOVRAM words. Word write $0001 to +0 (card reset). Then: if NOVRAM byte 0 bit 0 is set, D7+1. Sum bytes 0-14 and compare with byte 15 | ok (ROM image; passes trivially if the RAM were zeroed) |
| 18 | $1c028 | Expect `(+3) & $CC == 0` after the reset (IE, IP, LOCK, ACK) | ok |
| 19 | $1c036 | Expect CSR0 == 4 | ok |
| 20 | $1c042 | RAP←3,2,1,0, reading each back | ok |
| 21 | $1c050 | CSR1←0 reads 0; CSR1←$FFFE reads $FFFE | ok |
| 22 | $1c06c | CSR2←$FF, read & $FF; CSR2←0 | ok |
| 23 | $1c08e | CSR3←7, read & 7; CSR3←0 | ok |
| 24/25/27 | $1bf48→$1c0b6 | **Card RAM test**, $4000 bytes at +$8000, longword patterns taken from kernel code. Four passes: write+verify, verify, write inverted+verify, verify. Then byte lanes: `(+$8001)←0, (+$8000)←$FF` must read $FF00, and `(+$8001)←$AA` must read $FFAA. Then $01 to +1 | ok |
| **26** | $1bf5a→$1c0b6 | **NOVRAM test**, the same routine with D3 = $80 at +$C000. It writes 32 longs (64 nibble words) of pattern and compares `& $000F000F` after each write, then again in a verify-only pass, inverted, and so on | **FAILS.** `hp98643.sv` returns the fixed MAC image and ignores writes. Failure branch $1c0fc→$1c14c→$1c162 |
| 28.. | $1c168 | Six LANCE loopback tests, below | ok |

**Loopback set-up** ($1c472, $1c37c):
- +3←$08, then STOP via $1c31e, then +3←$00.
- The init block and descriptors are copied from template $114640 to RAM+0. TMD2 is at RAM+$24. CSR1 = $8000, CSR2 = 0, CSR3 = 4 (BSWP), CSR0 = $004B (INIT, STRT, TDMD, INEA).

| RAM | Contents |
|---|---|
| +0 | MODE |
| +2 | PADR (swapped words) |
| +8 | LADRF = 0 |
| +$10 | RDRA = $008018, RLEN 0 |
| +$14 | TDRA = $008020, TLEN 0 |
| +$18 | RMD: buffer $8048, OWN, BCNT −32 |
| +$20 | TMD: buffer $8028, $83 = OWN, STP, ENP |
| +$28 | TX frame |
| +$48 | RX buffer |

**Poll loop** ($1c3d8):
- Outer count D2 ($50, or $3E8 for the collision test). Each outer pass is a delay of 1001 × (5 NOP + subq + bpl). That is thousands of clocks on any core, against roughly 450 clocks for the RTL to do INIT, TX and RX.
- After each delay it reads CSR0. If ACK and IDON are set:
  - **IP (+3 bit 6) must already be set, or it fails with error 28.** The RTL raises IP together with IDON, because INEA came from the same write. ok.
  - Then it waits for TINT.
- On TINT it reads RMD1 and TMD3. TMD3.RTRY means failure/return.
- Then it polls CSR0 at most **30 times, with no delay**, for RINT. It compares 16 or 14 words of TX buffer against RX buffer.
- Callers ($1c39e) also require CSR0.ERR = 0, RMD1.ERR = 0 and TMD1.ERR = 0.

| # | MODE | TX bytes | Destination / filter | Compare | RTL |
|---|---|---|---|---|---|
| 1 | $0044 INTL+LOOP | 28 + LANCE FCS | unicast 14:02:36:25:58:47 = PADR | 32 bytes, including the FCS, which must be **44 7b 9f b0** | ok (FCS verified) |
| 2 | $004C +DTCR | 32 (software FCS) | same | 32 bytes; receive CRC must be good | ok |
| 3 | $8044 PROM | 28 + FCS | multicast 51:04:36:25:58:47 | 28 bytes | ok |
| 4 | $004C | 32 (FCS aa68db66) | same multicast, LADRF bit 3 only | 28 bytes | ok (hash = 3 verified) |
| 5 | $0044 | 28 + FCS | broadcast | 28 bytes | ok |
| 6 | $0054 COLL+INTL+LOOP | 28 | – | expects TMD3.RTRY = 1 and CSR0.ERR = 0 | ok |

### 2.4 `_hw_ext_test` ($1c24e): passes

- Takes PADR and the destination from NOVRAM **bytes 1-6**. That differs from bytes 2-7 in `read_local_address`, but it is consistent with itself.
- MODE = $0004 (external loopback, no INTL), 28 bytes, up to 6 tries.
- Checks:
  - TMD3.RTRY = 0 (35)
  - IDON and TINT and RINT (36, 37)
  - RMD1 OFLO/BUFF = 0 (38)
  - CSR0 BABL/MERR = 0 (39)
  - RMD1.ERR = 0 (40)
  - TMD3 BUFF/UFLO = 0 (41)
- CERR is not checked.
- The RTL treats LOOP without INTL as a loopback, so this passes.

### 2.5 `_hw_startup` ($1b7ee): passes

1. Card reset ($01 to +1).
2. Writes RAP 1/2/3 and CSR1 = init & $FFFF, CSR2 = (init>>16) & $FF, CSR3 = 4. **After each LANCE access it checks ACK = 1, or it panics.**
3. Builds the init block:

   | Field | Value |
   |---|---|
   | MODE | 0 |
   | PADR | NOVRAM MAC |
   | LADRF | all ones |
   | RDRA | ring at RAM+$18, RLEN 5 (32) |
   | TDRA | ring at RAM+$118, TLEN 4 (16) |
   | RMDs | BCNT −304, OWN |
   | TMDs | OWN cleared |

4. RAP←0, CSR0←$7F43.
5. Polls until +3 bit 6 (IP) is set. The timeout is 30 ms of `time`, but `time` is frozen at spl6, so in effect there is none.
6. `read_rdp`: needs IDON, and `CSR0 & $73 == $73`, or it panics.
7. `write_rdp($0140)`. Then +3←$80 (IE). card_state = 0.

`read_rdp`/`write_rdp` ($19a2a, $19aae) write $00 to +3, access the RDP, and need ACK, with up to 1000 retries. Otherwise they set card_state 9 and reset the card. The sticky ACK in the RTL always passes.

## 3. Ranked causes and fixes

### 1. NOVRAM is read-only in the RTL (certain)

Kernel: `_hw_int_test` NOVRAM test, $1bf5a/$1c0b6-$1c100, error 26.

RTL: `rtl/hp98643.sv`, the NOVRAM block (`nov_n`/`nov_byte`/`nov_nib`, and the header comment "Writes are ignored"). The design brief `lan_98643.md` §1.4 says the same.

The real part is a 64 × 4 NOVRAM: SRAM that recalls from EEPROM. The kernel's self-test treats it as RAM. Pass 1 re-verifies every word, so a 32-nibble array mirrored at +$40 would also fail: **all 64 nibbles must be distinct.**

The test at $1c2ee clears the NOVRAM and then writes the card reset before it checks the checksum. That implies the card reset recalls the EEPROM image. MAME's `novram_w` also stores writes.

Minimal fix:

```verilog
// 64 x 4 NOVRAM: nibble i = reg_off[6:1] (byte i>>1, high nibble first), mirrored every $80;
// host-writable in D3:0, recalled from the EEPROM image (two identical 16-byte copies) on reset/card reset
function [255:0] nov_image(input dummy);
	integer i; reg [7:0] b;
	begin
		for (i = 0; i < 32; i = i + 1) begin
			b = (i % 16 == 15) ? NOV_SUM : mac_byte(i % 16);
			nov_image[i*8 +: 8] = {b[3:0], b[7:4]};
		end
	end
endfunction
localparam [255:0] NOV_INIT = nov_image(1'b0);
reg  [255:0] nov;
wire   [5:0] nov_i = reg_off[6:1];
always @(posedge clk)
	if (reset || card_rst) nov <= NOV_INIT;
	else if (reg_cs && reg_we && is_nov && reg_be[0]) nov[nov_i*4 +: 4] <= reg_din[3:0];
wire   [3:0] nov_nib = nov[nov_i*4 +: 4];
```

This uses 256 flip-flops. Reads stay `{12'hFFF, nov_nib}`.

Recall on `card_rst` is the faithful choice, but it is not required. The kernel restores its saved copy at $1bf72 on every exit path. With no recall, the checksum test at $1c2ee would compare 0 with 0 and still pass.

The boot ROM and OpenBSD only read the NOVRAM, so they are unaffected.

### 2. In loopback, TINT is set about 160 clocks before RINT (low risk, defensive)

Kernel: $1c438-$1c44e. After it sees TINT, it allows only 30 back-to-back CSR0 polls for RINT.

RTL: `lance.sv` S_TXCMP sets `tint` before the S_RX pass over `lb`. On the real chip, receive and transmit of a loopback frame finish together.

This only matters if the CSR0 read lands inside that 160-clock window. The outer delay makes that unlikely.

Fix: in S_TXCMP, when `lb_pend`, hold a `lb_tint` flag instead of setting `tint`. In S_RXFIN with `src_lb`, set `tint` from `lb_tint`. Clear the flag on reset and STOP.

### 3. Nothing else in `drv_init` fails

The following match the RTL:
- ID/level checks
- the NOVRAM layout and checksum
- the status bits (IP raw with IE off, LOCK and ACK read back, bit 0 and bit 1 not tested)
- CSR1-3 read back while stopped
- the FCS byte order
- the LADRF hash (CRC bits 31:26, verified = 3 for 51:04:36:25:58:47)
- the 8-32 byte loopback limit (tests use 28+4 and 32)
- forced collision → RTRY with no CSR0.ERR
- IDON together with IP
- IDON_DLY 160 and the TX poll, both far inside the timeouts

CERR, BABL, MISS and MERR are never needed by the tests.

## 4. What could fail next (runtime, after the fix)

- **`hw_isr` ($1b500):**
  - Status bit 1 set → `hw_softreset`. The RTL keeps it at 0.
  - CSR0.IDON set inside the ISR → **panic**. The RTL only re-raises IDON on an INIT write when INIT=0. The ISR writes back `CSR0|$7F40`, which carries INIT=1, so this is safe.
  - RXON or TXON clear → `hw_softreset`, then `drv_restart` (the self-test again).
  - CSR0.MERR → card_state 4 and the card dies. The RTL never sets MERR.
  - CERR only counts NO_HEART_BEAT.
- **`hw_softreset` ($19b2c):** STOP, CSR3←4, then CSR0←$7F42. That is STRT with **no INIT**: the driver expects the init block's PADR, LADRF and rings to survive STOP.
  - The RTL keeps PADR, LADRF, RDRA/TDRA and rpos/tpos, but clears MODE. MODE is 0 in normal use, so this only matters in promiscuous mode (nettl/landiag).
  - After this path, CSR0.INIT reads 0. Only `hw_startup` checks `$73`.
  - The RTL does not reset rpos/tpos on STOP. If the real chip does, the driver would desync, but HP-UX does not rewind its ring pointers here.
  - This path only runs after a TX BUFF/UFLO error.
- **`isr_proc` TX completion ($1b258):**
  - Panics unless the completed TMD1 still has STP and ENP. The RTL preserves them, and `hw_send` always queues single-buffer $83 frames.
  - TMD3.BUFF → card_state 8 (dead).
  - TMD3.RTRY copies the TDR into `last_tdr` (statistics only).
- **`hw_send` ($1a424):** writes the TMD with byte writes (TMD1 low byte, then $83 to the high byte), then `write_rdp($48)`. The RTL handles both.
- **Second self-test from `lanc_init`:** it runs with the LANCE live from the first `hw_startup` (RX on, IE=1, IRQ masked at spl5/6). The test's STOP and card reset clean that up.
- **STRT at $1c00a:** briefly runs the RTL LANCE with MODE 0 and stale ring addresses until the card reset at $1c2fe. It could poll an old TMD, or write a wire frame into RAM that is about to be tested. This is harmless, because the RAM test rewrites everything and the reset stops the LANCE.
