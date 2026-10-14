; HP 9000/385 boot test program.
;
; Booted by the HP Boot ROM Rev 2.0 from a LIF volume (scripts/mklif.py
; wraps the raw binary in one load record and names it SYSTEST, so the ROM
; lists it as "1S SYSTEST": S is the first letter where the name differs
; from "SYSTEM_").  See docs/reference/lif_boot.md.
;
; State at entry (ROM 0x44E0-0x44E8): supervisor mode, IPL 7,
; A7 = 0xFFFFFDAC, A0 = our entry address, D6 = the ROM flags byte at
; 0xFFFFFED2, the console re-initialised (bitmap console on the 98550A),
; the ROM globals still at 0xFFFFF702 (pointer at 0xFFFFFED4).  Unused
; exception vectors trap to the ROM's "unexpected" handler.
;
; What it does:
;   1. LED code 0x5A (latch byte 0x1FFFF := ~code = 0xA5).
;   2. Draws test bars into the 98550A frame buffer (VRAM 0x200000,
;      1 byte/pixel, 2048-byte stride, 1280x1024 visible).
;   3. Prints two lines through the ROM's fixed console entry 0x150
;      (D0.w = row, 0-based; A0 = NUL-terminated string; preserves
;      D0-D1/A0-A1).
;   4. (TAILTEST=1) Checks a magic long at the end of the image (past the first
;      sector, so it only arrives if the ROM's multi-sector read worked).
;   5. LED code 0xA5 (latch 0x5A), then spins.  On a bad tail: LED code
;      0xEE (latch 0x11) and an error line instead.
;
; Build: tools/bootblk/build.sh

LED		equ	$0001FFFF	; diagnostic LED latch (write ~code)
VRAM		equ	$00200000	; 98550A frame buffer
STRIDE		equ	2048
WIDTH		equ	1280
ROM_PRINTLN	equ	$00000150	; JMP slot -> 0x5ED6: print A0 at row D0

LOADADDR	equ	$FFF00000	; must match the LOAD given to mklif.py

; TAILTEST=1 (default): pad the image to 1.5 KB and check its last long, so
; the load needs the ROM's multi-sector read (on SCSI that read goes through
; the 98620 DMA).  TAILTEST=0: a 216-byte image that fits in the first
; 256-byte sector, so the ROM loads it with programmed I/O only.
	ifnd	TAILTEST
TAILTEST	equ	1
	endif

		org	LOADADDR

start:
		move.w	#$2700,sr
		move.b	#$A5,LED		; code 0x5A (latch = ~code): running

		; --- bar 1: rows 704..735, colour 0xFF -------------------------
		lea	VRAM+704*STRIDE,a1
		moveq	#32-1,d1
		move.l	#$FFFFFFFF,d0
		bsr	fill_rows

		; --- bar 2: rows 752..783, colour 0x01 -------------------------
		lea	VRAM+752*STRIDE,a1
		moveq	#32-1,d1
		move.l	#$01010101,d0
		bsr	fill_rows

		; --- bar 3: rows 800..863, 64-pixel stripes 0xFF / 0x00 ----------
		lea	VRAM+800*STRIDE,a1
		move.w	#64-1,d1
.srow:		move.l	a1,a2
		moveq	#WIDTH/128-1,d2		; 10 pairs of stripes
.spair:		moveq	#64/4-1,d3
.son:		move.l	#$FFFFFFFF,(a2)+
		dbra	d3,.son
		moveq	#64/4-1,d3
.soff:		clr.l	(a2)+
		dbra	d3,.soff
		dbra	d2,.spair
		lea	STRIDE(a1),a1
		dbra	d1,.srow

		; --- text through the ROM console ------------------------------
		lea	msg1(pc),a0
		moveq	#2,d0
		jsr	ROM_PRINTLN
		lea	msg2(pc),a0
		moveq	#3,d0
		jsr	ROM_PRINTLN

	ifne	TAILTEST
		; --- check the tail of the image arrived (multi-sector load) ----
		cmp.l	#$C0DEB007,tail_magic
		bne.s	bad_tail
	endif

		move.b	#$5A,LED		; code 0xA5 (latch = ~code): done
done:		bra.s	done

	ifne	TAILTEST
bad_tail:	lea	msg3(pc),a0
		moveq	#4,d0
		jsr	ROM_PRINTLN
		move.b	#$11,LED		; code 0xEE: tail of the load missing
.hang:		bra.s	.hang
	endif

; fill d1+1 rows of WIDTH pixels starting at a1 with the long d0
fill_rows:
.row:		move.l	a1,a2
		move.w	#WIDTH/4-1,d2
.px:		move.l	d0,(a2)+
		dbra	d2,.px
		lea	STRIDE(a1),a1
		dbra	d1,.row
		rts

msg1:		dc.b	"HP9K385 LIF BOOT TEST: SYSTEST RUNNING",0
msg2:		dc.b	"LED 5A -> A5, BARS AT ROWS 704/752/800",0
		even

	ifne	TAILTEST
msg3:		dc.b	"ERROR: TAIL OF THE LOAD RECORD MISSING",0
		even
; Pad past the first 248-byte sector so the ROM's second (multi-sector)
; read is exercised, and end with a magic the program checks.
		ds.b	1024
tail_magic:	dc.l	$C0DEB007
	endif
