# SCSI: MB87030 SPC and the block-device disk target

RTL:
- `rtl/scsi/mb87030.sv` is the Fujitsu MB87030 SPC. It only plays the initiator role.
- `rtl/scsi/scsi_target.sv` is the SCSI target side: `UNITS` direct-access units on IDs 0 to `UNITS-1`, each backed by its own MiSTer block device, served by **one shared protocol engine**. A unit whose bit is set in the `CDROM` mask is a CD-ROM instead of a disk (see "CD-ROM personality" below). The 98265A uses `UNITS = 3`, `CDROM = 3'b100`.

Bench: `tb/tb_scsi.sv`.

References in MAME (tree `../mame`, paths under `src/devices/`):
- `machine/mb87030.cpp/.h`
- `bus/hp_dio/hp98265a.cpp`
- `bus/nscsi/hd.cpp`
- `machine/nscsi_hle.cpp` (nscsi_full_device)
- `machine/nscsi_bus.cpp`

MAME is treated as a behavioural spec. Where this RTL departs from MAME, the departure is listed under "Deviations" below.

## Bus convention

The bus uses active-high "asserted" signals. Each device has `scsi_*_o` outputs for the lines it asserts. The parent ORs all devices' outputs, data included, into the resolved bus. It feeds that bus back to every device as `scsi_*_i`, so a device also sees its own lines. Only the device that is currently sending drives non-zero data:

- The SPC forces its data outputs to 0 while I/O is asserted on the bus by someone else, which is the target driving.
- The disk drives data only between setting a byte and seeing ACK.

The bench checks that no data bit is ever driven by two devices.

Control-line bit order, used by `ext_ctrl` and in the bench. It is MAME's nscsi `S_*` order:

| bit | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|---|---|
| line | I/O | C/D | MSG | BSY | SEL | REQ | ACK | ATN | RST |

The phase is `{MSG, C/D, I/O}`, which is the same encoding as PCTL bits 2:0:
- 0 data out
- 1 data in
- 2 command
- 3 status
- 6 message out
- 7 message in

## mb87030

### Interface

| Port | Meaning |
|---|---|
| `CLK_HZ` | Clock frequency (default 33 MHz). It scales every delay and time-out. |
| `cs, we, rs[3:0], din, dout` | One register access per `cs` pulse. `dout` is combinational. Side effects, such as a DREG pop, happen on the clock edge. |
| `irq` | `SCTL[0] && INTS != 0`, as in MAME's `update_ints`. |
| `dreq` | The SPC wants a byte moved (see DMA below). |
| `dack_rd`, `dack_dout` | One byte out of the FIFO per pulse. The data is valid in the same cycle. If the FIFO is empty, the result is the last DREG value. |
| `dack_wr`, `dack_din` | One byte into the FIFO per pulse. It is dropped if the FIFO is full. |
| `ext_ctrl_wr`, `ext_ctrl[8:0]` | Replaces **all 9** of the SPC's own control lines (MAME `ctrl_write(val, S_ALL)`), bypassing diagnostic mode. Bit order is in the table above. |

### Registers

| rs | Read | Write |
|---|---|---|
| 0 BDID | `1 << id` | id = din[2:0] |
| 1 SCTL | SCTL | SCTL. Bit 0 = IE, 4 = arbitration enable, 5 = diagnostic mode, 7 = reset & disable (the value after reset is 0x80) |
| 2 SCMD | SCMD | Command, see below |
| 3 TMOD | TMOD | Stored only |
| 4 INTS | INTS | Write 1 to clear. Only bits that were already set are cleared, so an event in the same cycle is not lost. |
| 5 PSNS / SDGC | `{REQ, ACK, ATN, SEL, BSY, MSG, C/D, I/O}` | SDGC. Bit 5 (XFER_ENABLE) is masked, as on the MB87030. |
| 6 SSTS | `{INIT_CONN, TARG_CONN=0, SPC_BUSY, XFER_IN_PROGRESS, RST, TC==0, FULL, EMPTY}` | none |
| 7 SERR | 0 | none |
| 8 PCTL | PCTL | PCTL. Bit 7 = bus-free interrupt enable, 2:0 = expected phase |
| 9 MBC | 0 | none |
| 10 DREG | FIFO head (pops), or the last byte if the FIFO is empty | Push into the FIFO |
| 11 TEMP | TEMP | TEMP |
| 12-14 TCH/TCM/TCL | 24-bit transfer counter | Same |
| 15 EXBF | EXBF | Stored only |

SSTS FULL is suppressed during a DMA transfer, as in MAME.

### Commands

SCMD bit 4 drives RST. Unless SCTL[7] is set, it also aborts: the FIFO is cleared and the SPC disconnects and goes idle.

SCMD bits 7:5 select the command:

| Code | Command | Behaviour |
|---|---|---|
| 0 | Bus release | Clears the ATN-for-selection latch. It aborts a selection that is still waiting for bus free. |
| 1 | Select | With SCTL[4] set, arbitration runs first: wait for bus free, assert BSY and the ID bit, wait 32 clocks, then check for a higher ID. Selection then waits for bus free if it skipped arbitration, drives TEMP onto the data lines (software puts both ID bits there), and asserts SEL, plus ATN if it was latched. Then it waits for BSY. When BSY arrives it drops SEL and posts INTS 0x10. |
| 2 | Reset ATN | Clears the latch and drops ATN. |
| 3 | Set ATN | When idle it sets the latch for the next selection. Otherwise it asserts ATN. |
| 4 | Transfer | Bit 2 = program transfer, otherwise DMA. Bit 0 = padding ("terminal") mode. The command waits for REQ. If the bus phase is not PCTL[2:0], it posts INTS 0x08 (service required). Otherwise it moves TC bytes through the FIFO with a full REQ/ACK handshake. After the last byte of MESSAGE OUT it drops ATN, if ATN was set for the selection. On the last byte of MESSAGE IN, ACK stays asserted so that software can reject the message. Software releases it with command 6. Once TC = 0 and the FIFO is empty, it posts INTS 0x10. |
| 5 | Transfer pause | No-op, as in MAME. |
| 6 | Reset ACK/REQ | Drops ACK, when connected as initiator. |
| 7 | Set ACK/REQ | Manual handshake. In an input phase it latches the bus data into TEMP. Otherwise it drives TEMP onto the bus. Then it asserts ACK. |

### Interrupts (INTS)

| Bit | Meaning | Source |
|---|---|---|
| 0x20 | Disconnected | Set when the SPC is idle, PCTL[7] is set and every bus line is free (edge-triggered: it fires once per free-bus event). It is also set when the bus has been free for 400 ns (a bus settle delay) while the SPC is connected; MAME waits 10 ms. The window between `S_SEL_ID` and SEL going out, where a selection without arbitration is already "connected" on a free bus, does not count. In both cases INTS is set to exactly 0x20, as in MAME. |
| 0x10 | Command complete | Selection done, or transfer done. |
| 0x08 | Service required | Phase mismatch when REQ arrived during a transfer. |
| 0x04 | Time-out | Selection time-out. It sets TC to 0 and the SPC keeps driving SEL. Writing INTS with bit 2 set and TC = 0 ends the selection and releases the bus. Writing it with TC ≠ 0 starts the selection again. |
| 0x80, 0x40, 0x02, 0x01 | Selected, reselected, SPC hard error, reset condition | Never set. MAME does not set them either. |

### Timeouts and delays

MAME counts delays in 8 MHz chip clocks. Here they are converted to cycles as `N * ceil(CLK_HZ / 8 MHz)`, which is 5 cycles per chip clock at 33 MHz. The delays are:
- 1 clock: handshake steps
- 2 clocks: data setup before ACK
- 5 clocks: start of a transfer
- 10 clocks: selection steps, and from receiving a byte to sending ACK
- 32 clocks: arbitration

The selection time-out is `((TC & 0xFFFF00) + 15) * 2` chip clocks. They are counted on an 8 MHz tick that is derived from `CLK_HZ` with a fractional accumulator, so the time-out is exact on average. For example, TC = 0x002003 gives about 2 ms.

The bus-free disconnect delay is 400 ns, which is `ceil(CLK_HZ / 2.5 MHz)` cycles (14 at 33 MHz). MAME uses 10 ms. HP-UX 9 does not set PCTL[7]: before every selection it polls SSTS until the SPC is no longer connected. So with 10 ms, every HP-UX command cost about 12 ms: 8 KB raw reads ran at 440 KB/s, against 1.19 MB/s with 64 KB transfers.

MAME's 10-clock delay between receiving a byte and sending ACK limited DATA IN to about 2.1 µs per byte at 33 MHz (about 470 KB/s), and DATA OUT ran at about 1 MB/s. Real parts do about 1.5 MB/s in asynchronous mode. So a hardware (DMA) transfer in a data phase now skips every handshake delay (`fast` in the RTL; see Deviations). `tb_scsi_dma` times a 16-block DMA WRITE(10) and READ(10): 260k / 588k clocks before, about 96k each after (~6k clocks, ~180 µs, a block). Program transfers and the command, status and message phases keep MAME's delays, so the PIO paths the drivers were checked against are unchanged.

### DMA

`dreq` is combinational from registers plus the acknowledge in the same cycle:
- DATA IN: `FIFO count > dack_rd`.
- DATA OUT: the FIFO has room after any `dack_wr` in this cycle, and the bytes queued or in flight (FIFO + the byte on the bus that has not been ACKed yet + any `dack_wr` in this cycle) are fewer than TC.

`dreq` is enabled when a DMA transfer sees its first REQ in the right phase. It is cleared at command complete, on a phase mismatch, at disconnect, on reset and when a transfer command starts.

A DMA engine such as `hp98620`:
- can sample `dreq` in the same cycle as its own `dack_*`, and can commit to the next byte;
- must not move more bytes than TC.

The bench's DMA model does both: it issues back-to-back acknowledges and commits while it is acknowledging.

### Diagnostic mode (SCTL[5])

This is ported from MAME. Lines that the SPC sets go into a private register instead of onto the bus. The SPC's view of REQ/ACK/BSY/MSG/C/D/I/O is SDGC OR that register. Card direct control (`ext_ctrl`) still goes to the bus.

### Reset

`reset` performs MAME `device_reset`. Every register becomes 0, except SCTL, which becomes 0x80 (reset & disable). The FIFO is emptied, all lines and data are released and the SPC goes idle. While SCTL[7] is set, any non-idle state falls back to idle with the lines released, RST is released, and SCMD and INTS read 0. A select that is issued while the SPC is disabled is aborted.

HP-UX 9 ends its SCSI bus reset with SCMD = 0x10 (RST), SCTL = 0xC0, SCMD = 0, so RST is dropped by SCTL[7]. NetBSD's `spc_scsi_reset` drops it with an SCMD write while SCTL[7] is clear.

### Deviations from MAME

- MAME's arbitration-lost check `break`s out of the loop and then carries on with the selection anyway. Here, losing arbitration releases BSY and the data lines and goes idle. With ID 7, which the 98265A always uses, no one can outrank the SPC.
- MAME cancels the selection time-out on any `step()`, including a DREG or TEMP access. Here only BSY from the target, or software, ends the wait.
- After selection, the SPC stops driving the ID bits together with SEL. MAME leaves them on the bus until the next byte overwrites them.
- The SPC never drives data while the target asserts I/O (see the bus convention above).
- SSTS bit 3 shows the RST line. MAME never sets it.
- The bus-free interrupt with PCTL[7] is edge-triggered. MAME re-evaluates it on every `step()`.
- INTS write-to-clear only clears bits that were set before the write.
- `dreq` for DATA OUT stops once TC bytes are queued. MAME only drops it when the FIFO is full and relies on the DMA count.
- Reset-and-disable also clears the data lines. MAME leaves them.
- Bus free while connected disconnects after 400 ns, not MAME's 10 ms (see "Timeouts and delays").
- DMA data phases handshake with no chip-clock delays (see "Timeouts and delays"). On HP-UX 9 the old delays held raw-disk reads to ~375 KB/s with 64 KB transfers.
- MAME's own quirk is kept: a phase mismatch clears SPC_BUSY but not XFER_IN_PROGRESS.
- SCTL[7] (reset & disable) releases RST and clears SCMD and INTS. MAME leaves RST on the bus until the next SCMD write with SCTL[7] clear.
- A received byte goes into the FIFO together with ACK, after MAME's 10-clock delay. MAME pushes it when it sees REQ, 10 clocks before ACK. In that window, software that has already read the last byte still sees the target's REQ for it. NetBSD's `spc_datain_pio` returns as soon as it has its n bytes. `spc_intr` then finds REQ up in DATA IN and starts a zero-length transfer in the middle of the handshake, which hangs the bus. `tb_scsi_dma` catches this with a fast CPU.

### Not implemented

These are the same as in MAME:
- target mode: being selected or reselected (SCTL bits 1/2, INTS 0x80/0x40)
- synchronous transfers (TMOD)
- parity (SERR, SCTL[3])
- SCTL[6] control reset
- the intercept bit (SCMD bit 3)
- MBC
- the MB89351/2 interrupt-driven program transfer (SERR XFER_OUT)

## scsi_target

### One engine, several units

Only one target can be connected at a time, so one state machine, CDB, set of counters and one block buffer (`MAXB` blocks, 16 KB) serve every unit. The engine answers a selection carrying the ID bit of any of its units (an ID without an image answers too, and gets NOT READY; an ID at or above `UNITS` does not answer, so the initiator sees a selection time-out). The unit that won the selection is `cur`, and everything below applies to it, as if each unit were its own target.

Kept per unit, because it outlives a connection:
- the image: mounted, read-only, size in blocks (latched on that unit's `img_mounted` bit);
- the pending sense key and ASC, until REQUEST SENSE on that unit or its next command;
- the request lines `sd_rd` / `sd_wr` to its hps_io slot;
- CD-ROM units only: the unit attention after a mount, the 2048-byte block mode and the lead-out MSF.

Shared: the phase state machine, the CDB, IDENTIFY state, transfer length / position / LBA / block count, the MODE SELECT parameter bytes being received, REQUEST SENSE's output latch, and the sector buffer. `sd_lba` is one register shown on every slot, and `sd_buff_din` is the one buffer shown on every slot; hps_io only looks at the slot whose request it is serving.

A block request waits until no unit has one outstanding (`sd_rd`, `sd_wr` or `sd_ack` on any slot), so `sd_lba` never moves under a request, and the buffer takes `sd_buff_wr` / follows `sd_buff_addr` only for the connected unit's `sd_ack`.

### Target state machine

1. **Selection.** The disk is idle until it sees SEL, no BSY and its ID bit on the data lines. It waits 16 cycles for the bus to settle, which is about 480 ns. If SEL, no BSY and the ID bit are still there, it asserts BSY. It does not arbitrate and never reselects.
2. **Message out.** When SEL drops, ATN means MESSAGE OUT. The disk takes bytes for as long as ATN stays asserted. IDENTIFY (bit 7 set) sets the LUN. Other messages are ignored, and there is no MESSAGE REJECT, so SDTR or WDTR would not be negotiated.
3. **Command.** It then takes the CDB. Length is by group: 0 → 6, 1 and 2 → 10, 4 → 16, 5 → 12, and everything else → 6. It keeps 10 bytes.
4. **Data, status, message in.** Next come the DATA IN or DATA OUT phases, if any, then STATUS (0x00 GOOD or 0x02 CHECK CONDITION), then MESSAGE IN 0x00 (COMMAND COMPLETE). The disk frees the bus once the initiator drops ACK on that last byte.
5. **Bus reset.** SCSI RST from any device releases every line and returns the disk to idle. A block request that is in flight still finishes on the host side.

Each byte uses the full asynchronous handshake. The phase lines are set one cycle before REQ. The data is set together with REQ, and is dropped with REQ when ACK arrives.

### Commands

| Op | Command | Result |
|---|---|---|
| 00 | TEST UNIT READY | GOOD |
| 01 | REZERO UNIT | GOOD |
| 03 | REQUEST SENSE | 18 bytes, limited by the allocation length. An allocation length of 0 gives 4 bytes, the SCSI-1 rule. The sense is cleared afterwards. |
| 04 | FORMAT UNIT | GOOD, no-op. A FmtData parameter list is not taken. |
| 08 / 28 | READ(6) / READ(10) | DATA IN from the image. READ(6) with a count of 0 means 256 blocks. READ(10) with a count of 0 means GOOD with no data. |
| 0A / 2A | WRITE(6) / WRITE(10) | DATA OUT to the image. A read-only image gives DATA PROTECT/27. |
| 0B / 2B | SEEK(6) / SEEK(10) | GOOD |
| 12 | INQUIRY | 36 bytes, limited by the allocation length (see below). |
| 15 | MODE SELECT(6) | Takes CDB[4] bytes and discards them. GOOD. |
| 16 / 17 | RESERVE / RELEASE | GOOD |
| 1A | MODE SENSE(6) | See below. |
| 1B | START STOP UNIT | GOOD |
| 1D | SEND DIAGNOSTIC | Discards the parameter list (CDB[3:4] bytes). GOOD. |
| 1E | PREVENT ALLOW MEDIUM REMOVAL | GOOD |
| 25 | READ CAPACITY | Last LBA (blocks - 1) and 512. |
| 2F | VERIFY(10) | GOOD. With BytChk set, no data is taken either. |
| 35 | SYNCHRONIZE CACHE | GOOD |
| other | | CHECK CONDITION, ILLEGAL REQUEST/20 |

INQUIRY returns:
- peripheral type 0x00 (direct access, not removable), or 0x7F for a LUN other than 0;
- version 2 and response format 2;
- additional length 31;
- vendor `HP9K385 `, product `SCSI DISK       `, revision `1.0 `.

MODE SENSE(6) returns:
- **Header:** the WP bit for read-only images, and a block-descriptor length of 8, or 0 when DBD is set.
- **Block descriptor:** the number of blocks (saturating at 24 bits) and a block length of 512.
- **Page 03h (format device):** 16 tracks per zone, 32 sectors per track, 512 bytes per sector, interleave 1.
- **Page 04h (rigid disk geometry):** cylinders = blocks / 512, 16 heads, 3600 rpm.

Page 3Fh returns pages 03h and 04h. Any other page returns the header and block descriptor only, with GOOD status. Page control 01 (changeable values) returns the page bodies as zeros.

### Errors and sense

Checks run in this order:

1. Unknown opcode → ILLEGAL REQUEST/20.
2. INQUIRY and REQUEST SENSE always work.
3. LUN ≠ 0, taken from IDENTIFY if one was sent and otherwise from CDB[1][7:5] → ILLEGAL REQUEST/25.
4. No image → NOT READY/3A.
5. Write to a read-only image → DATA PROTECT/27.
6. LBA + count > blocks → ILLEGAL REQUEST/21.

When the image is missing and nothing else is pending, REQUEST SENSE reports NOT READY/3A.

The sense data format is:
- byte 0: 0x70
- byte 2: the sense key
- byte 7: 10
- byte 12: the ASC
- byte 13: ASCQ, always 0
- all other bytes: 0

Every command other than REQUEST SENSE first clears the stored sense. There is no UNIT ATTENTION after a reset or a media change.

### Block interface (hps_io, WIDE=1, BLKSZ=2)

A disk unit's request moves up to `MAXB` (32) 512-byte blocks: `sd_blk_cnt` is the block count minus 1, and `sd_buff_addr[12:0]` is the word index across the whole request (0 to 256 × blocks − 1). A CD-ROM unit always asks for one block, because Main's CD translation (`support/hp9k`) serves 512-byte requests. Each unit has its own `img_mounted` bit. hps_io allows at most 16 KB a request, which is 32 blocks.

The handshake matches `sys/hps_io.sv`:
- The disk sets `sd_lba` and `sd_blk_cnt` and raises `sd_rd` or `sd_wr`. Both stay stable until `sd_ack` rises, and the request drops in the cycle after that. hps_io asserts `sd_ack` together with `sd_buff_addr = 0` (command 0x17 or 0x18), and the block is finished when `sd_ack` falls. The disk waits for that fall before it uses the block or issues the next request.
- **Read (0x17):** each word arrives on `sd_buff_dout` with a one-cycle `sd_buff_wr` pulse at `sd_buff_addr`. hps_io increments the address two cycles later.
- **Write (0x18):** `sd_buff_din` is the buffer word at `sd_buff_addr`, registered, so it is valid one clock after the address changes. hps_io samples `sd_buff_din` at an `io_strobe`, many `clk_sys` cycles after it last moved the address. The MacQuadra800 core relies on the same thing.
- **Byte order:** little-endian. `[7:0]` is the even byte (the first on disk) and `[15:8]` is the odd byte. This is how the real HPS packs WIDE words. MacQuadra800's `ncr53c96.sv` documents it and found it on hardware. Note that its Verilator `sim_blkdevice.cpp` packs big-endian, so do not reuse that helper unchanged.

The buffer is two `MAXB` × 256 × 8 simple dual-port RAMs (even and odd bytes), 16 KB in all, which map to M10K. A READ or WRITE is cut into requests of up to 32 blocks. The SCSI side stops between requests: it fills the buffer and then writes it, or fetches it and then sends it. So an 8 KB HP-UX file-system block costs one HPS round trip instead of 16. There is no read-ahead across commands and no write-behind in the core. On the Main side, `support/hp9k/hp9k_disk.cpp` buffers writes, so a write request does not wait for its own `O_SYNC` SD write. Images are opened `O_SYNC`, and on the board that wait was about 8 ms a block, which held HP-UX to about 60 KB/s. A cache like MacQuadra800's `scsi_cache.sv` would add read-ahead across commands.

### Image and reset

An `img_mounted` pulse latches:
- `img_size` as blocks = size / 512, saturating at 2^32 - 1;
- `size != 0` as "mounted";
- `img_readonly`.

The mount state starts at zero and **is not cleared by `reset`**, because the HPS does not mount again after a core reset. `reset` clears the target state machine, the sense data and any pending `sd_rd` or `sd_wr`. hps_io may still complete a request that it had already picked up; the disk ignores it.

### CD-ROM personality (`CDROM = 1`)

The CD-ROM behaviour applies to the units whose bit is set in `scsi_target #(.CDROM(mask))`; the others behave as described above. The model is an HP-300-era SCSI CD-ROM such as the Toshiba XM-3301 or Sony CDU-561.

**Image.** The image is a flat run of 2048-byte data sectors, which is how MiSTer's Main presents CUE and CHD images. The block side still moves 512-byte host blocks: CD sector N is host blocks 4N to 4N+3.

**Block length.** The logical block length is 512 by default, which is what the HP 300 boot ROM and HP-UX 9 expect. MODE SELECT(6) changes it through the block descriptor:
- The block length is taken from parameter-list bytes 9-11, when the list is at least 12 bytes and the block-descriptor length (byte 3) is at least 8.
- A block length of 512 or 2048 is accepted.
- Any other block length gets CHECK CONDITION, ILLEGAL REQUEST/26 (invalid field in parameter list), and the setting is left unchanged.
- A list with no block descriptor is accepted and changes nothing. The rest of the list (density, pages) is ignored.

The block length goes back to 512 on `reset` and on every mount. It is **not** reset by SCSI RST, because there is no power-on UNIT ATTENTION to tell the host.

These commands work in the current block length:
- READ(6) and READ(10): the LBA and count are in current blocks. At 2048 they are converted to host blocks (×4).
- The range check: LBA + count must be ≤ image size / block length.
- READ CAPACITY: returns the last LBA and the current block length.
- The MODE SENSE block descriptor: returns the block count and length. The density code is 0.

**Commands that differ from the disk:**

| Op | Command | CD-ROM result |
|---|---|---|
| 12 | INQUIRY | Peripheral type 05h, RMB = 1 (byte 1 = 80h), ANSI version 2, vendor `HP9K385 `, product `SCSI CD-ROM     ` |
| 0A / 2A | WRITE(6) / WRITE(10) | DATA PROTECT/27, whatever `img_readonly` says |
| 04 | FORMAT UNIT | ILLEGAL REQUEST/20 (not supported) |
| 1A | MODE SENSE(6) | Header with WP set, plus the block descriptor. No pages are returned, 03h, 04h and 3Fh included. |
| 1B, 1E | START STOP UNIT, PREVENT ALLOW | GOOD. Eject is a no-op. |
| 43 | READ TOC | See below |
| 42 | READ SUB-CHANNEL | A 4-byte header: audio status 15h (no current audio status), data length 0, limited by the allocation length in CDB[7:8] |
| 44 | READ HEADER | LBA form only. It returns 8 bytes: data mode 1, then the LBA from the CDB. MSF = 1 gets ILLEGAL REQUEST/24. |
| 45, 47, 48, 4B, … | PLAY AUDIO and other audio commands | ILLEGAL REQUEST/20. Audio will come later through Main's CD-audio windows. |

**READ TOC (43h).** Only format 0 is supported; the format field is ignored. CDB[1] bit 1 is MSF, CDB[6] is the starting track, and CDB[7:8] is the allocation length.

The response starts with a header: TOC data length (total - 2), first track 1, last track 1. Then come 8-byte descriptors:
- **Track 1:** ADR/control 14h (ADR 1, data track). The address is LBA 0, or 00:02:00 in MSF.
- **Lead-out (AAh):** ADR/control 14h. The address is the image size in current logical blocks for the LBA form. For MSF it is (sectors + 150) frames as minutes:seconds:frames. That value is worked out once after a mount, by repeated subtraction (about 2 cycles per minute plus 1 per second).

The starting track selects what is returned:
- 0 or 1: header plus both descriptors, 20 bytes.
- AAh: header plus the lead-out descriptor only, 12 bytes.
- Anything else: ILLEGAL REQUEST/24 (invalid field in CDB).

The allocation length is honoured, while the header still states the full length.

**No medium and medium change.**
- With no image, every command except INQUIRY and REQUEST SENSE gets NOT READY/3A.
- A mount (an `img_mounted` pulse with a size other than 0) sets a UNIT ATTENTION flag, which survives `reset`. The next command other than INQUIRY or REQUEST SENSE gets CHECK CONDITION, UNIT ATTENTION/28 (not ready to ready transition), and the flag clears. TEST UNIT READY reports it too.
- If REQUEST SENSE arrives first, it reports 06/28 and clears the flag.
- Unknown opcodes are checked after the unit attention, as SCSI requires.
- The disk personality has no unit attention.

## How the 98265A card uses it (from `hp98265a.cpp`)

The card sits at DIO-I select code `sc`, which MAME defaults to 14, at `0x600000 + sc * 0x10000`. The card's 16-bit registers are:

| Word (byte offset) | Read | Write |
|---|---|---|
| 0 (+0x00) | 0x07 (card ID) | Card reset: control register = 0, SPC `reset` pulse |
| 1 (+0x02) | `control \| irq << 6 \| (level - 3) << 4` | control = data & 0x8F. Bit 7 = interrupt enable, bits 1:0 = DMA channel 0/1 enable (DE0/DE1) |
| 2 (+0x04) | The SCSI data bus: the resolved `scsi_data` at the card, the OR of all devices | Direct control, through `ext_ctrl`. Bit 7 → REQ, 6 → ACK, 3 → BSY, 2 → MSG, 1 → C/D, 0 → I/O. Everything else, including SEL, ATN and RST, is 0. |
| 3 (+0x06) | 0x88 | none |

To make `ext_ctrl` from a word-2 write `d`:

```
ext_ctrl = {1'b0, 1'b0, d[6], d[7], 1'b0, d[3], d[2], d[1], d[0]}
```

Each part of the card connects to the SPC as follows:

- **SPC registers.** SPC register n is at byte `+0x21 + 2n` (odd bytes, umask 0x00FF00FF over `+0x20..+0x3F`), so `rs = (addr - 0x20) >> 1`.
- **Interrupt.** The card interrupt is `control[7] && spc.irq`, at level `3 + SW1[1:0]` (MAME's default switch gives level 4). Read bit 6 shows the raw `spc.irq`.
- **DMA requests.** `dmar0 = DE0 && spc.dreq` and `dmar1 = DE1 && spc.dreq`.
- **DMA acknowledges.** A DMA acknowledge on a channel whose DE bit is clear is ignored. A read of such a channel returns 0xFF.
- **SCSI IDs.** The SPC is ID 7 on the bus. Software writes BDID itself. The SW2 SCSI address and parity switches are not used by the SPC in MAME.
- **Bus wiring.** The card ORs the SPC's `scsi_*_o` with every target's outputs and feeds the result back to all of them.

## Bench

`tb/tb_scsi.sv` puts one SPC and one `scsi_target` with four units (`UNITS = 4`, `CDROM = 4'b0100`) on the bus. Each unit has its own block-device model on a shared `sd_buff_*` bus that is muxed by `sd_ack`, as hps_io does:
- disk 0 has a 64-block image behind an hps_io-timed block-device model, which checks that `sd_rd`/`sd_wr` are held until `sd_ack` and dropped after it;
- disk 1 has a 16-block image (`tb_blkdev`, the same model packaged as a module), mounted part-way through, first read-only and then writable;
- ID 2 is a CD-ROM with an 8-sector image, also on a `tb_blkdev`;
- disk 3 has no image;
- ID 5 is absent.

A NetBSD-style register driver then runs:
- the `spc_init` order, register and FIFO readback, and card direct control;
- selection with arbitration, ATN and IDENTIFY;
- program-transfer INQUIRY;
- TEST UNIT READY, with the status taken by manual SET/RESET ACK;
- READ CAPACITY;
- READ(10) of 4 blocks by DMA, checked against the image;
- WRITE(10) of 2 blocks by DMA, checked in the image and read back;
- READ(6) by program transfer, with no ATN;
- MODE SENSE 3Fh;
- out-of-range READ and an unknown opcode, each followed by REQUEST SENSE;
- on ID 3, without arbitration: TEST UNIT READY → CHECK CONDITION, then REQUEST SENSE → NOT READY/3A, then INQUIRY;
- on the ID 2 CD-ROM:
  - before the mount, TEST UNIT READY gives NOT READY/3A;
  - after the mount: INQUIRY (type 05h, RMB, product string), then TEST UNIT READY → UNIT ATTENTION, REQUEST SENSE → 06/28, and TEST UNIT READY → GOOD;
  - READ CAPACITY at 512, then READ(10) at 512 by DMA, compared against the image;
  - MODE SELECT to 2048, then READ CAPACITY and MODE SENSE at 2048, then READ(10) and READ(6) at 2048, compared against the image;
  - a read past the end;
  - WRITE(10) and WRITE(6) → DATA PROTECT, FORMAT and PLAY AUDIO → ILLEGAL REQUEST, START STOP UNIT and PREVENT ALLOW → GOOD;
  - READ TOC in LBA and MSF form, from AAh, with a short allocation length, and with track 2 → ILLEGAL REQUEST/24;
  - READ SUB-CHANNEL;
  - MODE SELECT 1024 → ILLEGAL REQUEST/26, then back to 512 with READ CAPACITY and the READ TOC lead-out checked;
- several units at once:
  - ID 1 before its mount: NOT READY/3A, with ID 0 commands in between;
  - after the ID 1 mount: no unit attention on ID 1 or on the CD, INQUIRY and READ CAPACITY on every unit (type, product and size are the unit's own), and the CD's MSF lead-out is unchanged;
  - READ(10)s alternating between ID 0, ID 1 and the CD, each checked against its own image;
  - read-only per unit: WRITE on read-only ID 1 → DATA PROTECT and WP in MODE SENSE, WRITE on ID 0 → GOOD, ID 1's image untouched;
  - sense per unit: CHECK CONDITION on ID 0, ID 1, the CD and ID 3, other units' commands in between, then REQUEST SENSE on each returns its own sense, once;
  - block length per unit: MODE SELECT 2048 on the CD and on ID 0, READ CAPACITY on all three, then 2048-byte CD reads interleaved with disk reads, and READ TOC (a disk refuses it);
  - a writable remount of ID 1 leaves the CD at 2048 without unit attention, then a WRITE(10) to ID 1 lands only in ID 1's image;
  - a CD remount with a larger image: unit attention on the CD only, back to 512, a new MSF lead-out (02:15:25);
  - SCSI RST (SCMD bit 4) while ID 0 waits 20,000 clocks for its block: ID 0's request stays up until it is taken, and ID 1's next read waits for that block to finish before it raises its own request;
- on ID 5: selection time-out (INTS 0x04), then termination and recovery.

Along the way it checks:
- INTS, SSTS and PSNS;
- the `irq` pin;
- that ACK is held on the last MESSAGE IN byte;
- the bus-free interrupt (INTS 0x20);
- that no two devices drive the same data bit;
- that the CD-ROM never issues a block write, ID 3 never issues a request, and no two slots have a request or acknowledge up at once.

The bench was mutation-checked; each of these mutations makes it fail:
- SPC side: no same-cycle dack correction, no `inflight` term in `dreq`, ACK not held on MESSAGE IN, ATN not dropped, no phase check, TC not cleared on time-out;
- `sd_buff_din` byte swap;
- disk side: wrong sense key;
- CD side: no unit attention, no ×4 LBA conversion at 2048, no 150-frame pregap in MSF, no RMB bit, MODE SELECT accepting 1024, CD writable, READ CAPACITY block length stuck at 512.

The shared engine (2026-10-14) was mutation-checked as well; each of these makes the bench fail: sense in one shared slot, the read or the write request raised on unit 0's line whatever the unit, the CD flag applied to every unit, the buffer following unit 0's `sd_ack`, the image size, read-only or mounted state taken from unit 0 / any unit, unit attention and block length reset by any unit's mount, MODE SELECT changing a disk's block length, `cur` not latched at selection, the MSF recomputed on any mount, the unit attention cleared on the wrong unit, an absent ID answering selection, and the request interlock checking only the connected unit.

`tb/tb_scsi_dma.sv` puts the whole card (`hp98265a`) and the 98620 (`hp98620`) on a memory model. It is driven first like the boot ROM, with a READ(10) by DMA on channel 0, polled. Then it is driven like NetBSD 9:
- `spc_dio_attach` and `spc_init`;
- HP-UX's RST release through SCTL = 0xC0;
- the probe of IDs 0-2: TEST UNIT READY, REQUEST SENSE by NetBSD's exact `spc_datain_pio` loop, and a 36-byte INQUIRY by longword DMA on channel 1;
- STATUS and MESSAGE IN read from TEMP before SET ACK.

The bench runs at 2 clocks per register access, and again at 10 clocks per access.

It catches three bugs, each when that fix is reverted:
- the 98620 sampling the first byte of a DMA read on the previous channel (INQUIRY byte 0 = 0xFF);
- the early FIFO push;
- RST not released by SCTL[7].

Run it with:

```
verilator --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_scsi --Mdir build/obj_tb_scsi -o tb \
    tb/tb_scsi.sv rtl/scsi/mb87030.sv rtl/scsi/scsi_target.sv && build/obj_tb_scsi/tb
```
