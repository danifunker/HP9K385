# Boot ROM and 8042 paths that matter to the core

This is a reference for debugging the core against the HP 9000/380 boot ROM Rev 2.0 and the HIL 8042 firmware (1820-4784). It covers the soft-reboot entry, the 8042 handshake, the select-code scan, the ROM's interrupt handling, and the timing and reset-value assumptions behind them.

Addresses are CPU addresses in `docs/disasm/bootrom_rev2.0.asm`, or 8042 program addresses in `docs/disasm/8042_1820-4784.asm`. The label names used here (`req_reboot_1a4`, `hil_init_8042`, `irq_remote_console`, ...) come from `docs/disasm/tools/bootrom_notes.py` and `gen_8042.py`; regenerate the listings as described in `docs/disasm/README.md`. ROM globals are written as full addresses: 0xFFFFFDC0 is `$fdc0.w` in the listing. `A4` is the globals base 0xFFFFF702, so `($b,A4)` is 0xFFFFF70D.

Evidence tags, as in the README:
- **[V]** read from the code, or computed from it.
- **[I]** inferred and not confirmed by running the code.

---

## 1. Entry points and soft reboot

### 1.1 Entries [V]

| Entry | Goes to | D5 / flags | Used by |
|---|---|---|---|
| Reset vector | 0x418 `reset` | D5 = 2 (bit 1 = test memory) | power-on, OSD reset |
| 0x19C | 0x40A | D5 = 2, then joins the reset path at 0x46C, so only the register test is skipped | [I] OS "cold restart" |
| **0x1A4** | **0x40AE `req_reboot_1a4`** → 0x74E | 0xFFFFFDC0 = 0x000C | **HP-UX/BSD `reboot`** (NetBSD `doboot`: caches off, push 0, `JMP $1A4`; see `tools/rebootbench/reboot.s`) |
| 0x1C0 | 0x40E2 `req_reboot_1c0` → 0x40B4 | 0xFFFFFDC0 = 0x0012, otherwise the same as 0x1A4 | [I] unknown user |
| 0x140 | 0x4424 `restart_via_trap0` | TRAP #0 to supervisor mode, IPL 7, console reset, then `JMP (A0)` | ROM-internal restarts to 0x400/0x40E |
| 0x400 | D5 = 1 | Full reset sequence from 0x490 (alpha probe skipped): the top-16K fill destroys the globals | keyboard reset key (NMI, §2.4), 0x8162 |
| 0x40E | D5 = 0xD | Like 0x400, but bit 3 first copies ($b,A4) bit 1 (test memory) and ($a,A4) bit 0 from the old globals (0x474-0x48C) | 0x936, after the self-tests when ($86,A4) bit 0 is set |

### 1.2 Globals that steer a reboot [V unless tagged]

| Address | Meaning |
|---|---|
| 0xFFFFFDC0 (word) | **Reboot request.** Cleared on the reset path (0x6FC). Set to 0x0C by 0x1A4 and 0x12 by 0x1C0. Only "≠ 0" is ever tested, at 0x966 (direct boot) and 0x17942 (SCSI 5 s wait). |
| 0xFFFFFDC2-DCB | **System name**, 10 bytes, LIF style. On a normal boot 0x96C stores the pattern `"SYS",0`, and the LIF match overwrites it with the real name (`lif_boot.md` §3). It therefore still holds the name of the last system booted, e.g. `SYSHPUX`, when the OS jumps to 0x1A4. |
| 0xFFFFFEDC (long) | **Boot device** (MSUS [I]: NetBSD calls it that). Written when the search finds a system (0xBA0) and by the loader (0x4274). 0xE0FFFFFF means "none, search". |
| 0xFFFFFDCC | Console/boot flag byte (bit 2 is set by 0x40BA when a name is stored). |
| 0xFFFFFED4 | Pointer to the globals = 0xFFFFF702. |
| ($b,A4) = 0xFFFFF70D | Boot flags. Bit 1 = run the RAM test. Bit 3 = "user typed" (cleared by the keyboard set-up at 0x72AC). **Bit 4 = memory set up**, set by step 398 at 0x26B0 on every completed boot. Bit 5 = DMA usable. Bit 6 = 0x880000 extension present: it suppresses `RESET` and the 8042 checks, and never applies on a 380. |
| 0xFFFFFED2 | Bit 3 = "no 8042 keyboard". It is set at 0x752 on every entry and cleared when the 8042 passes (0x1ADE). |
| 0xFFFFFDB8 | HIL result. Bit 0 = loop up with no keyboard, bit 1 = bad report byte, bit 2 = no report. |
| ($d0,A4) / ($cc,A4) | Remote-console type and card base. Step 27000 sets them to 0xFF / 0x800000, meaning none. |

### 1.3 What `req_reboot_1a4` does [V]

```
0x40AE  $fdc0 = $0C
0x40B4  if byte $fdc2 == 0:  $fdc0 = 0                    -> 0x74E   (ordinary boot)
        else: $fdcc |= 4
              if byte $fdc3 != 0                          -> 0x74E   (keep the device in $fedc)
              else $fdcc &= ~4, $fedc = $E0FFFFFF         -> 0x74E   (name kept, device forgotten)
```

0x74E is in the middle of the reset path, after `reset_globals_init`. From there the reboot runs the same code as a cold boot: IPL 7, flag bytes, stack 0xFFFFFDAC, the bus-error slot, `sysreg_5f400e_clear`, `cpu_detect`, PTM init (LED 0x20), EEPROM probe, test-mode/table selection, the ROM-extension scan, and then **the whole step table**.

### 1.4 Cold boot vs soft reboot

| Stage | Cold (0x418) | Soft (0x1A4) | Evidence |
|---|---|---|---|
| Register-file test, top-16K fill (0x4AE), 64K touch, lamp test, alpha probe, top-16K pattern test | runs | **skipped** (RAM contents and the ROM's RAM JMP slots survive) | [V] |
| Globals init 0x6E8-0x74C (($b,A4) = D5, $fdc0 = 0, $fed9 = 0, ($cb,A4) = 0, the 0x400000/0x880000 pokes) | runs | **skipped**: ($b,A4) keeps the previous boot's value | [V] |
| 0x74E-0x926: flags, PTM init, `cpu_detect`, EEPROM, ROM-extension scan | runs | runs | [V] |
| `sub_0093e` (0x7AA): reuse the old memory bounds when ($b,A4) bit 4 | no-op | reinstates $fdce = 0xFFFFFAC0 and the ($44/$48,A4) block | [V] code, [I] meaning |
| Step 31000: 8042 command 0x31, `RESET`, PTM re-init | runs | runs | [V] |
| Steps 27000-4980 (console, checksum, 8042 report wait, HIL init) | runs | runs | [V] |
| Step 1000 RAM sizing / step 400 RAM test / step 398 set-up | run (step 400 only if ($b,A4) bit 1) | **skipped**, because ($b,A4) bit 4 is still set from 0x26B0 of the previous boot. The "RAM n Bytes" line is still printed. | [V] |
| Steps 800/700 (HP-IB, DMA), step 200 select-code scan with every card test | runs | runs | [V] |
| After the tests (0x966) | "System Search Mode", auto-boot the first `SYS*` found | **$fdc0 ≠ 0: boot the stored name directly** with `sub_040ea(name, $fedc)` (0x97E-0x9B4). No search listing. If the name is not found: "SYSTEM NOT FOUND" and a hang (0x9C2 jumps to itself). If the name is all spaces, it restarts at 0x40E. | [V] |
| SCSI card self-test (sc 14) | bus reset, no wait | **bus reset, then a 5 s wait** (§3.3) | [V] |

The two reboot-only rows apply only while 0xFFFFFDC0 ≠ 0, i.e. when a name was stored at 0xFFFFFDC2. With an empty name, 0x40B4 clears 0xFFFFFDC0, and the soft reboot searches and boots like a cold one, with no 5 s wait.

[I] All of this assumes that the OS leaves the ROM's area 0xFFFFF702-0xFFFFFFFF alone. If an OS cleared it, ($b,A4) = 0, so sizing would run and the RAM test would not.

**VBR.** The ROM never writes VBR on the way from 0x1A4 until 0x1926 (step 19990, after `ext_hook_call(2)`) [V]. A 68040 reset clears VBR, but `JMP $1A4` does not, so an OS that jumps there with VBR ≠ 0 takes every early bus-error probe through its own table. Those are the EEPROM probes, the 248 ROM-extension probes, step 32000 and the DIO-II console search. The ROM also never writes TC [V, README §1.7], so the OS must leave the MMU off. Both are the OS's job; the core only has to keep `RESET` from touching the CPU's control registers.

---

## 2. 8042 / HIL

### 2.1 Boot ROM sequence [V]

Command bytes go to 0x428003 and data to 0x428001. Status is read at 0x428003: bit 0 = OBF and bit 1 = IBF. The high nibble is the 8042's `MOV STS` tag.

| When | Where | To the 8042 | Meaning (8042 side, §2.2) | ROM expects |
|---|---|---|---|---|
| Step 31000, IPL 7 | 0x14E2 | cmd **0x31** | Copy RAM 0x2D-0x31 (tick counter) to RAM 0x13-0x17 (`cmd_20_3f`). It does **not** touch RAM 0x12. | IBF clear within about 1 ms, otherwise it skips the send |
| | 0x1504 | **`RESET`** instruction, unless ($b,A4) bit 6 | Pin reset of the 8042 and the DIO cards (core: `dio_reset`, PLAN 2026-10-15/16) | — |
| | 0x1506 | — | `ptm_init`, then `delay_us(50)` | — |
| Step 4990, IPL 7 | 0x1AAC | — | — | Any byte within `kbd_read(500000)`. The timeout is (500000/200 + 1) ms = **about 2.5 s**, not the 0.5 s the README states. Then two more status reads must be equal with high nibble 0x7, and the byte must be **0x8E**. |
| `hil_init_8042` (0x71C2), IPL 7 | 0x71EC | — | Read status and data once (flush) | — |
| | 0x71F0 | cmd **0xA0** + data 00 00 00 01 | R5 = 0x20; the data go to RAM 0x20-0x23. [I] NetBSD `HIL_SETARD`: auto-repeat delay/rate = 0. The pointer stops short of 0x24, so no tone starts. | — |
| | 0x720A | cmd **0x5C** (test mode 2/3, the normal boot) or **0x5E** | RAM[4] low 5 bits = 0x1C or 0x1E (`cmd_40_7f`). [I] 0x5C = NetBSD `HIL_INTON`; the meaning of bit 1 is unknown. | — |
| | 0x721E | cmd **0x11** | Deferred read: RAM[0x11] is returned with STS 0x40 (`cmd_defer`, sent from 0x27D) | A 0x4x byte, waited for **forever** (`kbd_get_4x_forever`, 0x7308). Other bytes are discarded. Bit 4 → $fdb8 b0 ("HP-HIL"). Bit 5 with (b & 7) ≠ 2 → ($d3,A4) = 1. |
| | 0x724A | cmd **0x12** | RAM[0x12] = keyboard ID & 0x1F | stored in ($d2,A4), the language |
| | 0x7264 | if ($d3,A4) = 1: cmd **0xEB** + data **0x97** | R5 = 0xFB, so RAM[0x7B] = 0x97. Bit 7 makes the main loop reconfigure the loop (0x22D → `sub_70b`). [I] NetBSD `HIL_WRITELPCTRL` / `LPC_RECONF`. | — |
| | 0x7274-0x7296 | — | Installs level 1 → 0x7456 (`irq1_hil`), NMI (vec 31) → 0x4EC4, and 0xFFFFFF34 → 0x701A | — |
| End of step 4990 | 0x6F8A | if the 8042 reported 0x8E ($fed2 bit 3 clear), with or without a keyboard: cmd **0xA3** + 0xF8 0x08, a 0.3 s wait, then the same again | Tone (`SETTONE`: the pointer reaches RAM 0x24 and the tone starts) | — |
| Later | 0x4488 (`restart_via_trap0` path) | cmd **0x5F**, then drain the 8042's output | RAM[4] low bits = 0x1F (all off) | — |
| Keyboard-reset NMI | 0x702E | **0x5F**, **0xB2**, **0xB2** | 0xB2 releases the NMI (P2.6, NetBSD `HIL_CNMT`) | — |

All of `hil_init_8042` runs at **IPL 7 with no timeouts** (0x72F8/0x7300/0x7308 poll forever). An 8042 that sent 0x8E and then stops answering hangs the boot with LED code 0x22 (latch 0xDD).

### 2.2 8042 firmware side [V]

- **Reset (0x000).** `EN FLAGS`, timer start, beeper silenced, **STS = 0x70**. Then `check_warm_signature` (0x19C):
  - **Warm** (RAM[0x6F] = 0xAA and RAM[0x7F] = 0x55): `init_regs` (R4 = 0x1F, R5 = 0x53, queue pointers 0x40, RAM[0x7B] = 0x17), then **0x8E is sent at once** (0x06F). There is **no loop configuration**: RAM[0x11], RAM[0x12] and RAM[0x7A] keep their previous values, and so do the MLC and the devices.
  - **Cold** (no signature): clear RAM 0x01-0x7D, then **write the signatures at once** (0x3FB: 0x6F = 0xAA, 0x5FB: 0x7F = 0x55). `cold_init2` sets RAM[0x11] = 0x30 and RAM[0x12] = 0x1F and calls `sub_70b`, which starts the loop configuration: loop status RAM[0x7A] = 0, RAM[0x11] = 0x30. It then sets R2 bit 0, meaning "report when done".
- **Loop configuration** (`hil_loop_state`, 0x72A, run on MLC interrupts). The first frame is a command frame: MLC W1 = 0x08 (command bit, address 0) and W0 = **0xFE** (0x739-0x74F). PLAN 2026-10-15 calls it DHR. The first device identified sets RAM[0x12] = ID & 0x1F and RAM[0x11] = 0x28 or 0x2A (0x7B7-0x7C3). The end of the configuration sets RAM[0x7A] \|= 0x08 (0x1C2, configuration good). A loop error sets RAM[0x7A] = 0x80 (0x700, configuration failed).
- **`post_init` (0x05E)** sends **0x8E** only once RAM[0x7A] has bit 3 or bit 7 set. A cold 8042 therefore reports only after the loop configuration has finished or failed. PLAN 2026-10-15 measured about 40 ms with the loop closed.
- **Command groups used by the ROM** (decoder at 0x100):

  | Group | Effect |
  |---|---|
  | 0x00-0x1F | Deferred: send RAM[cmd] with STS 0x40 |
  | 0x20-0x3F | Copy RAM[cmd−4..cmd] to RAM 0x13-0x17. The README says cmd−5 → 0x12, which is wrong. |
  | 0x40-0x7F | RAM[4] low 5 bits = cmd & 0x1F |
  | 0x80-0xBF | Data pointer = cmd & 0x3F. 0x9x/0xBx also handle the NMI and masks. |
  | 0xE0-0xEF | Next data byte → RAM[0x70 + n] (the pointer is 0xF0 \| n, and its bit 7 selects this path) |
  | 0xF0-0xFF | Deferred read of RAM[0x70 + n] |

  RAM 0x70-0x7F is the RTC scratch area and also holds the loop status (0x7A) and the loop control byte (0x7B).

### 2.3 What the HP-HIL line means [V]

The line is printed at 0x1B4E-0x1B88, after `hil_init_8042` (or after `hil_find_dio_card` when the 8042 failed):

| Condition | Flag | Printed |
|---|---|---|
| No byte within about 2.5 s, or the status is not 0x7x / not stable | $fdb8 b2 | **"HP-HIL Failed"**. In both failure rows `hil_find_dio_card` (0x70AA) runs instead of `hil_init_8042` and searches the DIO select codes for an HP-HIL card (ID & 0x1F = 9). |
| A byte arrived but it is not 0x8E | $fdb8 b1 | **"HP-HIL.Keyboard Failed"** |
| 0x8E, and RAM[0x11] bit 4 set (0x30: loop up, no keyboard identified) | $fdb8 b0 | **"HP-HIL"**. Step 3000 then offers "Type R RETURN for internal RS-232 console", and 0x1B9C searches for a remote console. |
| 0x8E, and RAM[0x11] = 0x28 or 0x2A | — | **"HP-HIL.Keyboard"**. The two beeps follow in both 0x8E rows. |

This explains the failures in the decision log:
- **Soft reboot without an 8042 reset.** A configured 8042 never sends 0x8E again, so the result is "HP-HIL Failed". This is also what MAME prints.
- **`RESET` during a cold configuration.** The signature is already written, so the 8042 warm-starts with RAM[0x11] = 0x30 and no reconfiguration, and the result is "HP-HIL". That happened when the configuration took longer than the time to step 31000 (about 0.1 s, PLAN 2026-10-14).
- **OSD reset that keeps the 8042's block RAM.** The same warm start.

**The 8042's RAM must survive a `RESET` and must be cleared, or at least lose its signature, on a power-on or OSD reset.**

### 2.4 Keyboard reset key (NMI) [V]

1. The 8042 pulls P2.6 low (0x258/0x6F1). NMI → vec 31 slot → 0x4EC4 `nmi_dispatch`.
2. If KBDNMIST (0x478005 bit 2) and 8042 status bit 2 are both set, it jumps through 0xFFFFFF34 to 0x701A `nmi_kbd_reset_key`. That routine sends cmd 0x5F, then 0xB2 twice, and reads RAM[5] twice with cmd 0x05.
3. It then restarts at **0x400** through 0x4424. If ($86,A4) bit 1 is set, it only sets ($87,A4) = 2 and executes RTE.
4. Any other NMI goes to 0xFFFFFF22. That slot is the parity handler 0x4E02 after step 400; otherwise it holds `JSR 0x4F66`.

---

## 3. Select-code scan (step 200, 0x1FA0)

### 3.1 Probe loop [V]

- **DIO-I.** For sc = 0..31 at 0x600000 + sc × 0x10000:
  - `set_led(0x40 | sc)`, so the **latch shows 0xBF − sc** (sc 9 = 0xB6, sc 14 = 0xB1, sc 21 = 0xAA). The LED stays there while that card's test runs, so a hang leaves the select code on the LEDs.
  - Read the ID at +1 & 0x7F. A bus error resumes at 0x229C and means "empty".
  - `sub_0878c` runs for every occupied select code except sc 7 when the internal HP-IB (which owns sc 7) was found at step 800 (0x1FE8-0x1FF6).
- **DIO-II.** sc 132-255 at 0x1000000 + (sc − 132) × 4 MB, LED = sc (latch = ~sc). The card size comes from +0x101.
- **Printing.**
  - `scan_card_name` (0x2308) builds "*name* at *sc*" in 0xFFFFFDD2. The name comes from the table at 0x5A59 (ID & 0x7F). The core's 98644 reports ID 0x02, so it prints **"HP98626 (RS-232) at 9"**.
  - The line is printed **before** the card test (0x2062) and again after it (0x2250), with " Failed" appended on failure (`scan_mark_failed`).
  - The console card gets " (Console)".
  - Multi-select-code cards skip codes: ID 0x51, and ID & 0x1F ∈ {0x1A, 0x1C, 0x1D}.
  - [V] README §1.9 lists ID 0x05 as "98622 GPIO"; ID 0x05 is the 98642 RS-232 MUX (name table 0x5AAD, test 0x7D36), and the 98622 is ID 0x03.

### 3.2 Card actions for the core's cards

| Card | When / where | What the ROM does | Must hold |
|---|---|---|---|
| **98644 serial, sc 9, ID 0x02** (0x42 prints "HP98644") | step 200, `test_98644_loopback` 0x4B1A, with A0 = card + 1 | The 8250 is at odd bytes +0x11.. (A0 + 0x10 = RBR/THR/DLL, +0x12 = IER/DLM, +0x16 = LCR, +0x18 = MCR). Sequence: LCR = 0x80, DLM = 0, DLL = 7, LCR = 7, MCR = 0x1F (loopback + OUT1/OUT2/RTS/DTR). Then for each bit 0x01..0x80: THR = bit, `delay_us(1000)`, RBR must equal the bit. Afterwards MCR = 0, LCR = 0x80, DLL = 0x40, LCR = 7. **It never writes IER (DLAB = 0) or the card's IE/control at +3.** | The loopback echo must arrive within 1 ms. Divisor 7 on a 2.4576 MHz crystal is about 21.9 kbaud, so one 8N2 character takes about 0.5 ms [V computed]. |
| **98265A SCSI, sc 14, ID 0x07** | step 200, `scsi_card_selftest` 0x17838 → `card_selftest_run` 0x84CE → `scsi_selftest_cmd` 0x16F7A | Generic card self-test protocol: cmd 0 = list, 1 = run test *n*, 3 = message. Test level D7 = 2 by default (0x84D2); it is 1 or 3 only when ($a,A4) bit 0 is set. At level 2 the list is **tests 1 and 2**. Test 2 (0x171C8) runs three routines: **`scsi_card_reset(card, 1)`**, **`scsi_card_reg_test`** (0x18912) and **`scsi_spc_reg_test(card, 0)`** (0x18CF8). | see §3.3 |
| **98620 DMA** | step 700, 0x1DE2, LED 0x28 | Bus-error probes decide the name:<br>- 0x500000 absent: nothing printed.<br>- 0x508000 present: "HP98620A".<br>- 0x508000 absent and 0x500004 absent: "HP98620B".<br>- 0x508000 absent and 0x500004 present: "DMA-" + the two bytes at 0x500012/13; for type 3 (98620C), `hpux9_boot.md` §5.<br>`dma_reg_test` (0x1603C) then writes walking 1s and 0s and reads them back, masked: 0x500004 (& 0x8F), 0x50000C (& 0xFF), and for type 3 also 0x500100/0x500200 + 0/2/4/6 (& 0xFFFF) and +8 (& 0x06FF). After each pattern it reads 0x500000 and 0x500008. On failure: " Failed" and ($b,A4) bit 5 cleared. | Registers read back as written under those masks. [I] A pattern write must not start a transfer. |
| **98643 LAN, sc 21, ID 0x15** | step 200, `test_98643_lan` 0x488C | Prints the MAC and "AUI"/"THIN", then runs the internal test (register test, RAM test, LANCE loopback); the external test only runs if ($a,A4) bit 0 is set. | `lan_98643.md` §2: it is a step-by-step spec |
| **Internal HP-IB** (0x478000; not in the scan) | step 800, 0x4996, LED 0x24 | 0x478003 & 0xC1 must be 0x80, before and after writing 0x7E to it. Then `tms9914_init` (0x4AB8) and `test_tms9914` (0x4A16), which:<br>- send aux commands 0x80 and 0x93, the address, then aux 0x00 (a software-reset sequence [I]);<br>- **set the interrupt masks IMR0/IMR1 to 0** (`movep.w` at +0x11);<br>- set the address to 21 (system controller, +5 bit 7) or 20;<br>- as system controller, send IFC for 100 µs and REN;<br>- check the address status (& 0xE6) for 0 at the start, then 0x02 after aux 0x8A, 0x84 after aux 0x89, and 0xA0 at the end and INT0/INT1 & 0xFFFD = 0x1200. | Prints "HP-IB" or "HP-IB Failed". [I] TMS9914A aux-command meanings. |
| **98550A** (0x560000; not in the scan) | step 27000, console search 0x1518 | ID & 0x1F = 0x19 with bit 6 clear; the 68k module pointer must be 0; then the init tables, the font, and the checksum of the first 8 KB of the card ROM (LED 0x0C). See README §1.9 and §2. | [I] The ROM's use of the card's interrupt register was not traced. |

### 3.3 98265A details [V]

**`scsi_card_reset(card, rst)`** (0x1787E):
1. +1 ← 0 (card reset), SCTL (+0x23) ← 0.
2. If `rst`: **SCMD ← 0x10** (assert RST), then `delay_us(30)`.
3. BDID ← 7 − (+7 & 7). MAME's +7 reads 0x88, which gives ID 7.
4. SCTL ← 0xC0, which drops RST.
5. SCMD, TMOD, PCTL, TCH/TCM/TCL, TEMP and SDGC ← 0.
6. **If `rst` and 0xFFFFFDC0 ≠ 0: `delay_us(0x4C4B40)` = 5 s** (0x17942-0x17952). The only caller that passes `rst` = 1 is test 2 (0x171DE), so every boot asserts the bus reset once per card, and only a reboot request adds the 5 s wait. [I] The wait gives the targets time to recover from the reset; on a cold boot, power-up already provides that time.

**`scsi_card_reg_test`** (0x18912) starts with a card reset, then checks:

| Write | Check | Error code |
|---|---|---|
| +3 ← 0x7F | (+3 & 0xCF) == 0x0F. Uses 0xC7/0x07 when ID bit 5 is set, i.e. the 16-bit card. | 6 |
| +3 ← 0 | (+3 & 0xCF) == 0. **The SPC-interrupt bit 6 must read 0.** | |
| +5 ← 0 | — | |
| — | +7 bit 7 must be 1 | 9 |
| — | +7 bit 4 must be 0 | 3 ([I] "fuse burned out"; the error texts are at 0x16C60) |
| +1 ← 0 (card reset) | (+3 & 0xCF) == 0 | 6 |
| +5 ← 0 | If +5 then reads 0: +5 ← 0xFF, and +5 must then read nonzero | 0x0A |

**`scsi_spc_reg_test`** (0x18CF8):
- BDID walking test: write *n* = 0..7, read back 1 << *n*.
- SCTL ← 0x80..0xFF and read back; SCTL ← 0x7F reads back 0x7F.
- **After a card reset, SCTL must read 0x80.**
- SCMD write sequence.
- Register behaviour: `scsi.md`.

### 3.4 Card state left by an OS [V for the ROM side; the outcome depends on the core's levels]

The core's levels are: HIL 1, HP-IB 3, SCSI 4, serial 5, PTM 6, HIL NMI 7, plus the DMA and graphics levels (`hp385_top.sv`).

**The ROM relies on the `RESET` at step 31000 to clear the cards.** It clears almost nothing itself before step 2000 drops the mask to IPL 0:

| Source | Quietened by the ROM? | Effect if still pending after step 2000 |
|---|---|---|
| PTM (level 6) | Yes. `ptm_init` at 0x7AE (and 0x1506) leaves every CR bit 6 (IRQ enable) clear, well before step 2000. | — |
| 8042 OBF (level 1) | Handled by `irq1_hil`, which reads status and data | — |
| **98644 (level 5)** | **Never**: neither IER nor the card IE is written | `irq_remote_console` (0x80CE) runs. With no remote console it executes RTE without touching any card, so the level-triggered request re-enters at once and the ROM livelocks. An interrupt already pending storms from step 2000. One that is enabled but not pending (e.g. THRE after HP-UX read IIR) starts at the sc 9 loopback test, because the THR writes re-arm THRE; the screen then ends at "HP98626 (RS-232) at 9" with latch 0xB6. Seen on the board after an HP-UX reboot, and `tools/rebootbench` DIRTY=1 reproduces it (PLAN 2026-10-16). |
| 98265A (level 4) | Only by the card reset at the start of its own test (sc 14) | Between step 2000 and sc 14: vec 28 → `JSR 0x4F66` → **"UNEXPECTED USE OF FFFFFFAC"** and a halt |
| Internal HP-IB (level 3) | IMR0/1 = 0 at step 800 | Steps 1000/900 run first: "UNEXPECTED USE OF FFFFFFB2" and a halt |
| 98620 / 98643 / others | Their own tests, at step 700 / sc 21 | "UNEXPECTED USE OF *slot*" and a halt |

This is why `RESET` must reset the DIO cards: interrupt enables, pending requests and the 8250. On the real machine the 68040's RSTO drives the DIO bus reset [I]; MAME wires `reset_cb` only on its DIO16 machines.

---

## 4. Interrupts during boot

### 4.1 IPL timeline [V]

| Span | SR mask |
|---|---|
| Reset → 0x74E | 7 (a 68040 reset sets 7; 0x74E ORs in 0x700 on every path) |
| Steps 32000 … 3000, including the `RESET`, the console and the whole 8042 handshake | **7**. Only NMI can be taken. |
| **Step 2000** (0x1BBA) | `andi #$F8FF` → **IPL 0**, and $fed3 bit 1 is set |
| Steps 1000 … 10 (sizing, HP-IB, DMA, RAM test, select-code scan, boot) | 0. Individual routines raise the mask locally: `hil_init_8042` to 7, many console/keyboard routines to 6, and level-1/level-5 handlers run at IPL 6. |

### 4.2 RAM JMP slots and handlers [V]

Vectors 3-71 and 125-255 point at 6-byte slots at the top of RAM (README §1.1). The vector numbers below are autovectors: vec 25 = level 1 … vec 31 = level 7.

| Slot | Vector | Contents | Installed by |
|---|---|---|---|
| 0xFFFFFFFA | 2 (bus error, via 0x4D3A once A7 > 0x200) | `JMP 0x4D5C` → frame cleanup, then `JMP (A6)` | 0x798, on every path |
| 0xFFFFFEE0-0xFFFFFFF9 (all other slots) | everything else | `JSR 0x4F66` `unexpected_exception`: " UNEXPECTED USE OF " + slot address, then `halt` (0x4D8A: NMI slot → RTE, `STOP #$2700` forever) | step 4990 at 0x1B24, after the 8042 report |
| 0xFFFFFFBE | 25, level 1 | `JMP 0x7456` `irq1_hil` | `hil_init_8042` 0x7274 |
| 0xFFFFFFA6 | **29, level 5** | `JMP 0x80CE` `irq_remote_console` | step 4980 (0x8318), **after** the 4990 fill |
| 0xFFFFFFB2 − 6 × (level − 3) | the remote-console card's level | `JMP 0x80CE` | `install_remote_console_irq` 0x8054, only when ($d0,A4) < 0x80 |
| 0xFFFFFF9A | 31, NMI | `JMP 0x4EC4` `nmi_dispatch` | 0x7290 |
| 0xFFFFFF34 / 0xFFFFFF22 | NMI sub-slots | 0x701A (keyboard reset) / 0x4E02 (parity, step 400) | 0x7282 / 0x255E |
| TRAP #0-#9, line A/F, privilege, TRAPV, zero divide, illegal, **and the bus-error slot 0xFFFFFFFA** | 32-41, 2, 4, 5, 7, 8, 10, 11 | `JMP 0x4DAA` (Pascal ESCAPE 6); TRAP #10 → 0x4DB0. In the search and loader, a bus error is an ESCAPE, not a resume. | `install_trap_slots` 0x4C52, called by the system search (0xAC6) and the loader (0x40F8) |

**Before step 4990** the slots hold the following:
- On a cold boot, the top-16K fill pattern (0xEEEE1111 from 0x4AE, then the 0x610 pattern test). An NMI taken in that window crashes.
- On a soft reboot, whatever the previous boot (or the OS) left there [V for the cold fill, I for the crash].

**An unexpected bus error after RAM is up** goes through 0x4D5C to `JMP (A6)`. Outside a probe, A6 is a Pascal frame pointer, so the CPU jumps into the stack. A spurious BERR therefore looks like a wild crash, not an error message.

### 4.3 `irq_remote_console` (0x80CE) [V]

1. `ori #$700` then `andi #$FEFF`, which leaves IPL 6.
2. `ext_hook_call(5)`, which returns at once without an upper ROM, then VBR = 0.
3. A0 = ($cc,A4). If ($d0,A4) ≥ 4 unsigned (0xFF = no remote console), it goes straight to RTE (0x8158 → 0x821E).
4. Otherwise it reads the 8250 IIR at A0 + 0x15: with IIR = 4 (receive) it reads RBR; it checks the card's +3 bit 7, and so on.

Even with a remote console, a THRE (IIR 2) or modem-status interrupt is never acknowledged.

---

## 5. Other traps for a core implementer

**Timing**
- **The PTM is the clock for everything.** T2:T3 is read as a 32-bit down-counter at 4 µs per tick (README §1.8).
  - `delay_us(n)` waits n/4 − 5 ticks.
  - `timeout_start` takes µs. The `kbd_*` timeouts take D0 and convert it to **(D0/200 + 1) ms**: 0x0F → 1 ms, 500000 → about 2.5 s [V computed].
  - A PTM that does not count halts the CPU with LED 0x20.
- **Long waits in sim.** The SCSI 5 s reboot wait, the 0.3 s between the beeps, the 7 × 166 ms LED blink (step 20) and a silent 8042 (2.5 s) are all real PTM time. A full-system soft-reboot sim spends about 5 s of simulated time in the SCSI test alone.
- **8042 vs the ROM's `RESET`.**
  - A cold 8042 must finish its loop configuration before step 31000 (about 0.1 s after reset). Otherwise the `RESET` makes it warm-start with RAM[0x11] = 0x30 (§2.3).
  - After 0x8E the status must stay 0x7x across two reads (0x1AB6-0x1AD0). A key byte queued right behind the report with a different STS tag would fail the check.
- **CPU-speed loops.** The lamp test (0x4FA, 8 × 65536 DBRA passes) and the RAM-sizing / 64K-touch loops depend on CPU speed and on fast bus errors, not on the PTM.

**Reset values the ROM checks**

| Hardware | Value |
|---|---|
| 8042 | STS 0x7x with the report 0x8E |
| Internal HP-IB | +3 & 0xC1 = 0x80 |
| 98265A after a card reset | +3 & 0xCF = 0, SCTL = 0x80, +7 bit 7 = 1 and bit 4 = 0 |
| 98643 after a card reset | status & 0xCC = 0, CSR0 = 4 (`lan_98643.md` §2.1) |
| 98620 | registers hold walking-bit patterns |
| CPU | CACR bit 31 reads back (README §1.7) |
| 0x5F4000 block | must exist: 0x5450 is an unprotected read-modify-write |

**Bus errors** (README §1.3)
- Every absent address in the probe list must assert BERR quickly.
- The DIO-II range is probed twice per boot: by the console search (step 27000) and by the scan (step 200).
- Before RAM exists, writes into ROM space (the 040's exception frames) must be ignored, except at the LED latch at 0x1FFFF.

**Keep the 8042's RAM across `RESET`; clear it on a full reset** (§2.3).

**Where MAME is wrong or missing**

| Area | MAME behaviour |
|---|---|
| DIO reset | No DIO reset on the 380's `RESET`, so a soft reboot gives "HP-HIL Failed" and leaves the cards dirty |
| 98644 interrupt | Not wired, and its +3 bit 6 never shows a request (`hpux9_boot.md` §8) |
| LED latch | `led_w` covers the whole ROM range, so the boot-time frame writes hit the LEDs |
| 0x5F4000 block | Not mapped |
| Nereid timing and Catseye +0x518 | Not modelled. The core can accept and ignore them. |

### 5.1 Corrections to `docs/disasm/README.md`

These were found while writing this file. The README was not edited.

| README section | Correction |
|---|---|
| §1.5 step 4990, and the "time sinks" list | The 8042 report wait is about 2.5 s, not 0.5 s. |
| §3.2 decoder, 0x20-0x3F row | The command copies RAM[cmd−4..cmd] → RAM[0x13..0x17]. For 0x31 that is a snapshot of the tick counter at RAM 0x2D-0x31. This answers open question 3. |
| §3.2 decoder, 0x00-0x1F row | It is a deferred read of RAM[cmd] with STS 0x40. |
| §1.9 ID table | ID 0x05 is the 98642 MUX, not the 98622 GPIO (ID 0x03). |
| `halt` comment | Said "autovector-1 slot"; it is the NMI (vec 31) slot. Fixed in `bootrom_notes.py`. |
