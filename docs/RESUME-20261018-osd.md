# Resume: HP9K385 OSD standard, build and board test (2026-10-18)

Paste the prompt below into a new session to continue. The background follows it.

---

## Prompt

> Continue the HP 9000 Model 385 MiSTer core in `HP9K385` (this repo).
> Read `docs/RESUME-20261018-osd.md` (this file) first, then
> `docs/RESUME-20261016.md` for the board procedure and the earlier state.
> The OSD standard this work follows is `docs/osd-standard.md` in the
> HP 9000/715 repo (`hp9000-715`, commit a959e77).
>
> Work through "Remaining items" below in order: build, then test on the
> board. The core is about to be released. The gate has already been run for
> this change (see below), so skip it this time. Quartus needs only this repo:
> no `scratch/`. The ROMs are already on the board's SD card.
>
> - **Process:**
>   - Short sims only.
>   - `scripts/prebuild_gate.sh` must pass before every Quartus build that changes the machine RTL (`rtl/`). Not this time: see "Gate" below.
>   - Build in the `build/wt_head` worktree (`git worktree add build/wt_head <commit>` if it isn't there). The `.rbf` is copied only on success.
>   - Commit on master; never push. Don't push Main_MiSTer either.
>   - If other sessions share the build machine, agree the Quartus order with them first and wrap the flow in `flock /tmp/quartus.lock`. The fitter needs about 3.6 GB. Never run two fitters, or a fitter next to a `-j 0` C++ build.
> - **The board** is the MiSTer at 192.168.99.92, and you may use it.
>   - Drive it yourself with `misterkvms-cli` (screenshot, type, key, mouse; on m900 it is `~/Downloads/MiSTerKVMS-0.9.5-linux-x86_64/misterkvms-cli`). Never use MiSTer's own screenshot command.
>   - Load cores and mount images only through the OSD. Copying a `.rbf` with `tools/mister/board.sh push` is fine.
>   - Shut guests down cleanly before any reset or image swap.
>   - Log in as root and run commands yourself; don't hand the user steps. Ask before answering any guest-OS *setup* prompts.
> - **Reporting:** report results with evidence (timing summary, board screenshots).

---

## State at the end of 2026-10-18

### Done: `5f21c31` (master), the OSD on the computer-core standard

| Page | Row | Status bits | Takes effect |
|---|---|---|---|
| top | `Pri. disk (ID 0)`, `Disk (ID 1)`, `CD-ROM (ID 2)` | slots S0 S1 S2 | at once (media) |
| top | `Load ROM` (`F0,ROM`, not remembered; ioctl index 0 = the boot0.rom path) | - | at once (resets) |
| top | `Memory` 32MB, 64MB, 128MB, 8MB, 16MB | `[4:2]` | at reset |
| top | `Network interface` eth0, None, eth1, macvlan, tap0 | `[14:12]` | the link at once (Main's hp9k_enet reads the bits); `None` **removes the 98643A card**, at reset |
| top | `Changes pending` (`h0-`, menumask bit 0), `Apply and reset` (`R[0]`) | - | - |
| P2 Video | `Aspect ratio` | `[122:121]` | at reset |
| P3 Input | `Swap Alt/Win keys` No, Yes | `[19]` | at once |
| P5 Advanced | `Fast boot` Yes, No | `[5]` | at reset |

- `HP9K385.sv`: `cfg` is `status` latched while `reset` is high. `ram_sel`, `fast_boot`, `lan_present` and the aspect ratio come from `cfg`. `lan_wire.ena` is `cfg_lan && status[14:12] != 1`. `cfg_pending` compares `[5:2]`, "LAN fitted" and `[122:121]`.
- **Removed rows:**
  - The `LAN card (98643A) Present/Absent` row (status bit 15, now unused). `None` replaces it.
  - The `T[0] Reset` button: the top page has one action only.
- **Config version is `v,2`.** The meaning of `None` changed, so Main drops a `.CFG` saved under `v,1` once. The board then starts from the defaults (32 MB, eth0, Fast boot Yes).
- **No Machine page (P1):** there is only one model, and no case buttons are modelled. The HIL keyboard's own Break/Reset key (PS/2 Pause, with Ctrl+Shift for the NMI) stays on the keyboard.
- **Debug switches:** the core has none in the OSD and no `ifdef` debug builds. The `ev_*` trace port and the CPU `debug_*` outputs are left unconnected in the shell, and Quartus prunes them. Nothing was removed.
- **`Readme.md`:**
  - The status paragraph is up to date. It used to say "no hardware build has been tested".
  - There is a new OSD section with an MGL example for Load ROM.
- **Main_MiSTer needs no change.** `support/hp9k/hp9k.cpp` reads only `[14:12]` by bit range, not by label.

### Gate on `5f21c31` (on m900)

- Since `fa70a88` only the shell changed; the machine RTL did not.
- These steps passed: all the unit benches, the disk boot (ID 0) and the CD boot (ID 2).
- The user stopped the gate during the soft-reboot step: the board test covers the rest.
- The gate does not simulate `HP9K385.sv` (the sim top is `hp385_top`), so the Quartus build is the first check of the shell edits.

### Not done yet

- `5f21c31` has not been built in Quartus yet, so nothing is on the board. The board still runs the release candidate `HP9K385_076aec6.rbf` (= `releases/HP9K385_20261017.rbf`, master `59b8b00`).
- The build was taken out of m900's shared Quartus queue (Pippin, then the SS20 session) and moved to a free machine.

---

## Remaining items

1. **Build** `5f21c31` (or later) in `build/wt_head` with Quartus 17.0.2 Lite: `quartus_sh --flow compile HP9K385`, about 28 min. The fitter uses seed 4 (`HP9K385.qsf`).
   - Check timing in `output_files/HP9K385.sta.rpt`: setup and hold on clk_sys, clk_ram and pll_hdmi.
   - The shell changed, so seed 4 may no longer meet timing. If it misses, walk seeds as on 2026-10-17 (`build/seeds/`) and commit the seed that passes.
   - Copy the `.rbf` to `build/HP9K385_<commit>.rbf`.
2. **Board test**, through the OSD as a user would:
   - Push and load the core. Then:
     - The top page matches the table above.
     - The P2, P3 and P5 pages open.
     - The old `.CFG` was dropped: Memory 32MB, eth0, Fast boot Yes.
     - No "Changes pending" right after the core load. If it shows, Main sent `status` after the ROM load ended the reset; latch `cfg` again once at the first status change after start, or check the order in Main.
   - Change Memory to 128MB: "Changes pending" appears, and the machine keeps running at the old size. Apply and reset: the notice goes, and the ROM's RAM line shows 128 MB.
   - Boot HP-UX (`HP-OS.img` on Pri. disk). Check `lan0` with `hpux/dhcpclient`, then shut down cleanly.
   - Network interface None, then Apply and reset: the ROM no longer lists the LAN card or does its network boot wait (about 12 s). Set it back to eth0 and Apply and reset.
   - Load ROM: pick `boot0.rom`. The machine resets and boots.
   - Swap Alt/Win keys: Yes, then in an hpterm L Win acts as Extend char and L Alt as Insert line. The mapping is the same as the HP 9000/715's (the PS/2 codes are swapped before `ps2_hil_keymap`).
   - NetBSD (`NetBSD92.img`): boots to login, the keyboard works, clean shutdown.
   - Save settings in the OSD with the final values (128MB, eth0, Fast boot Yes).
3. **Release.** Once the board test passes, copy the `.rbf` to `releases/HP9K385_<date>.rbf` and commit it, replacing `HP9K385_20261017.rbf` (its OSD is the old one). Note the build and test in `docs/RESUME-20261016.md` or a new resume file.

The open items in `docs/RESUME-20261016.md` (the NetBSD HIL hang, SCSI read-ahead, the HP9K715 slot mask in Main, UnixBench) are unchanged.
