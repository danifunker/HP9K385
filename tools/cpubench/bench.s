; HP 9000/385 CPU baseline benchmark.
;
; A boot program (loaded from a LIF volume like tools/bootblk/test.s; see
; that file for the state the ROM leaves) that runs a fixed set of small
; kernels and times each one twice:
;   - LED markers: the latch is written with $10+2k before kernel k and
;     $11+2k after it, so the simulator's [LED] lines give the exact clock
;     (and dispatch count) of each kernel;
;   - the 6840 PTM timer 1, free running at 250 kHz (4 us per tick, 132
;     clocks at 33 MHz), read before and after, printed on the console
;     with each kernel's checksum.  This is what a run on hardware reports.
; Every kernel is a pure function of its inputs, so the checksums are the
; same on any correct CPU; compare them between runs.
;
; Caches (CACHE=1, default): the transparent translation registers make
; RAM ($FFxxxxxx) copyback for data and cachable for instructions, and the
; low 16 MB (I/O, VRAM, LED latch) non-cachable serialised; then CACR
; enables both caches.  CACHE=0 leaves the caches off.
;
; Build: tools/cpubench/build.sh

LED		equ	$0001FFFF	; diagnostic LED latch
PTM		equ	$005F8000	; 6840: register n at PTM+1+2n
ROM_PRINTLN	equ	$00000150	; print A0 at row D0 (preserves D0-D1/A0-A1)
LOADADDR	equ	$FFF00000	; must match the LOAD given to mklif.py

BUF		equ	$FF900000	; 4 MB of scratch RAM, FF900000-FFCFFFFF
BUF2		equ	$FFA00000
CHASE		equ	$FFB00000	; pointer-chase area, 2 MB

	ifnd	CACHE
CACHE		equ	1
	endif

		org	LOADADDR

start:
		move.w	#$2700,sr
		lea	$FFFFFD00,sp
		bsr	ptm_init

	ifne	CACHE
		move.l	#$FF00C020,d0		; RAM: copyback (CM=01), any FC
		movec	d0,dtt0
		move.l	#$0000C040,d0		; low 16 MB: non-cachable serialised
		movec	d0,dtt1
		move.l	#$FF00C000,d0		; instructions from RAM: cachable
		movec	d0,itt0
		moveq	#0,d0
		movec	d0,itt1
		cinva	bc
		move.l	#$80008000,d0		; DE | IE
		movec	d0,cacr
	endif

		lea	results(pc),a5		; a5 -> {ticks, checksum} per kernel
		moveq	#0,d6			; kernel index

		; ---- untimed set-up: pattern data and the pointer-chase ring ----
		lea	BUF,a0
		move.l	#(512*1024)/4-1,d1
		move.l	#$12345678,d0
.fill:		move.l	d0,(a0)+
		add.l	#$9E3779B9,d0
		subq.l	#1,d1
		bpl.s	.fill
		bsr	chase_build

		lea	kernels(pc),a4
.next:		move.l	(a4)+,d0
		beq.s	.report
		move.l	d0,a3
		bsr	run_kernel
		bra.s	.next

.report:	bsr	report
		move.b	#$F0,LED
.done:		bra.s	.done

; run the kernel at a3: LED marker, PTM read, call, PTM read, LED marker
run_kernel:
		move.b	d6,d0
		add.b	d6,d0
		add.b	#$10,d0
		move.b	d0,LED
		bsr	ptm_read
		move.w	d0,-(sp)
		jsr	(a3)			; result in d7
		bsr	ptm_read
		move.w	(sp)+,d1
		sub.w	d0,d1			; down counter: start - end
		move.b	d6,d0
		add.b	d6,d0
		add.b	#$11,d0
		move.b	d0,LED
		moveq	#0,d0
		move.w	d1,d0
		move.l	d0,(a5)+
		move.l	d7,(a5)+
		addq.w	#1,d6
		rts

; ---- PTM: timer 1 continuous, 16 bits, internal 250 kHz clock ----
ptm_init:
		move.b	#$01,PTM+3		; CR2: bit 0 selects CR1 at register 0
		move.b	#$01,PTM+1		; CR1: hold in internal reset
		move.b	#$FF,PTM+5		; MSB buffer
		move.b	#$FF,PTM+7		; timer 1 latch = $FFFF
		move.b	#$02,PTM+1		; CR1: internal clock, run
		rts

; d0.w = timer 1 count (MSB read latches the LSB)
ptm_read:
		moveq	#0,d0
		move.b	PTM+5,d0
		lsl.w	#8,d0
		move.b	PTM+7,d0
		rts

kernels:	dc.l	k_alu, k_branch, k_muldiv, k_l1read, k_l1copy
		dc.l	k_stread, k_stwrite, k_memcpy, k_chase, k_fpu, k_icache
		dc.l	0
NKERN		equ	11

names:		dc.b	"ALU     ",0
		dc.b	"BRANCH  ",0
		dc.b	"MULDIV  ",0
		dc.b	"L1READ  ",0
		dc.b	"L1COPY  ",0
		dc.b	"STREAD  ",0
		dc.b	"STWRITE ",0
		dc.b	"MEMCPY  ",0
		dc.b	"CHASE   ",0
		dc.b	"FPU     ",0
		dc.b	"ICACHE  ",0
		even

;=======================================================================
; kernels: each returns its checksum in d7, may use d0-d5/d7/a0-a2
;=======================================================================

; register ALU: 20000 x 9 ops + loop
k_alu:
		moveq	#0,d7
		move.l	#$13579BDF,d0
		move.l	#$2468ACE0,d1
		move.w	#20000-1,d5
.l:		add.l	d0,d7
		eor.l	d1,d7
		rol.l	#3,d7
		sub.l	d1,d0
		lsr.l	#1,d1
		or.l	d0,d1
		not.l	d0
		swap	d1
		addx.l	d0,d7
		dbra	d5,.l
		rts

; data-dependent branches and calls: 10000 LFSR steps
k_branch:
		moveq	#0,d7
		move.l	#$ACE1ACE1,d0
		move.w	#10000-1,d5
.l:		bsr.s	.lfsr
		btst	#0,d0
		beq.s	.even
		addq.l	#3,d7
		bra.s	.j
.even:		subq.l	#1,d7
.j:		cmp.b	#$80,d0
		bhi.s	.big
		add.l	d0,d7
.big:		dbra	d5,.l
		rts
.lfsr:		lsr.l	#1,d0
		bcc.s	.nx
		eor.l	#$D0000001,d0
.nx:		rts

; 32-bit multiply and divide: 4000 x (mulu.l, muls.l, divu.l, divs.l)
k_muldiv:
		moveq	#0,d7
		move.l	#123456789,d0
		move.w	#4000-1,d5
.l:		move.l	d0,d1
		mulu.l	#2654435761,d1
		add.l	d1,d7
		move.l	d0,d1
		muls.l	#-40503,d1
		eor.l	d1,d7
		move.l	d7,d2
		lsr.l	#1,d2
		addq.l	#7,d0
		divu.l	d0,d2
		add.l	d2,d7
		move.l	d7,d2
		asr.l	#2,d2
		move.l	d0,d3
		lsr.l	#8,d3
		addq.l	#1,d3
		divs.l	d3,d2
		add.l	d2,d7
		dbra	d5,.l
		rts

; cache-resident loads: sum 1 KB, 200 times
k_l1read:
		moveq	#0,d7
		move.w	#200-1,d5
.o:		lea	BUF,a0
		moveq	#256/8-1,d4
.l:		add.l	(a0)+,d7
		add.l	(a0)+,d7
		add.l	(a0)+,d7
		add.l	(a0)+,d7
		add.l	(a0)+,d7
		add.l	(a0)+,d7
		add.l	(a0)+,d7
		add.l	(a0)+,d7
		dbra	d4,.l
		dbra	d5,.o
		rts

; cache-resident copy: 1 KB -> 1 KB, 100 times, then sum the copy
k_l1copy:
		move.w	#100-1,d5
.o:		lea	BUF,a0
		lea	BUF2,a1
		moveq	#256/8-1,d4
.l:		move.l	(a0)+,(a1)+
		move.l	(a0)+,(a1)+
		move.l	(a0)+,(a1)+
		move.l	(a0)+,(a1)+
		move.l	(a0)+,(a1)+
		move.l	(a0)+,(a1)+
		move.l	(a0)+,(a1)+
		move.l	(a0)+,(a1)+
		dbra	d4,.l
		dbra	d5,.o
		lea	BUF2,a0
		bra	sum_1k

; streaming loads: sum 512 KB once (misses every 16 bytes)
k_stread:
		moveq	#0,d7
		lea	BUF,a0
		move.w	#(512*1024)/32-1,d5
.l:		add.l	(a0)+,d7
		add.l	(a0)+,d7
		add.l	(a0)+,d7
		add.l	(a0)+,d7
		add.l	(a0)+,d7
		add.l	(a0)+,d7
		add.l	(a0)+,d7
		add.l	(a0)+,d7
		dbra	d5,.l
		rts

; streaming stores: fill 512 KB at BUF2, then sum the first 1 KB
k_stwrite:
		lea	BUF2,a0
		move.l	#$5A5A0001,d0
		move.w	#(512*1024)/32-1,d5
.l:		move.l	d0,(a0)+
		move.l	d0,(a0)+
		move.l	d0,(a0)+
		move.l	d0,(a0)+
		move.l	d0,(a0)+
		move.l	d0,(a0)+
		move.l	d0,(a0)+
		move.l	d0,(a0)+
		addq.l	#1,d0
		dbra	d5,.l
		lea	BUF2+511*1024,a0
		bra	sum_1k

; copy 256 KB from BUF to BUF2+512K, then sum the last 1 KB of the copy
k_memcpy:
		lea	BUF,a0
		lea	BUF2+512*1024,a1
		move.w	#(256*1024)/32-1,d5
.l:		move.l	(a0)+,(a1)+
		move.l	(a0)+,(a1)+
		move.l	(a0)+,(a1)+
		move.l	(a0)+,(a1)+
		move.l	(a0)+,(a1)+
		move.l	(a0)+,(a1)+
		move.l	(a0)+,(a1)+
		move.l	(a0)+,(a1)+
		dbra	d5,.l
		lea	BUF2+767*1024,a0
		bra	sum_1k

; dependent loads: 8192 hops round a ring spread over 2 MB
k_chase:
		lea	CHASE,a0
		moveq	#0,d7
		move.w	#8192-1,d5
.l:		move.l	(a0),a0
		add.l	a0,d7
		dbra	d5,.l
		rts

; FPU: 3000 x (fadd, fmul, fdiv, fsqrt) in extended precision
k_fpu:
		fmove.l	#3,fp0
		fmove.l	#7,fp1
		fdiv.x	fp1,fp0			; 3/7
		fmove.l	#1,fp2
		fmove.x	fp2,fp3
		move.w	#3000-1,d5
.l:		fadd.x	fp0,fp2			; fp2 += 3/7
		fmove.x	fp2,fp4
		fmul.x	fp0,fp4
		fadd.x	fp4,fp3
		fmove.x	fp3,fp5
		fdiv.x	fp2,fp5
		fsqrt.x	fp5
		fadd.x	fp5,fp3
		dbra	d5,.l
		fmove.l	fp3,d7			; round to integer
		fmove.l	fp2,d0
		swap	d0
		eor.l	d0,d7
		rts

; straight-line code bigger than the 4 KB I-cache: 8 KB, 20 passes
k_icache:
		moveq	#0,d7
		moveq	#1,d1
		move.w	#20-1,d5
.l:		bsr	icode
		dbra	d5,.l
		rts

;=======================================================================

; d7 = sum of 256 longs at a0
sum_1k:
		moveq	#0,d7
		move.w	#256-1,d4
.l:		add.l	(a0)+,d7
		dbra	d4,.l
		rts

; ring of 8192 nodes, node i at CHASE + ((i * 1597) mod 8192) * 256,
; each pointing at the next; the last points back at the first
chase_build:
		moveq	#0,d1			; i
		moveq	#0,d2			; (i * 1597) mod 8192
.l:		move.l	d2,d0
		add.l	#1597,d2
		and.l	#8191,d2
		addq.l	#1,d1
		cmp.l	#8192,d1
		bne.s	.notlast
		moveq	#0,d2
.notlast:	lsl.l	#8,d0
		add.l	#CHASE,d0
		move.l	d2,d3
		lsl.l	#8,d3
		add.l	#CHASE,d3
		move.l	d0,a0
		move.l	d3,(a0)
		cmp.l	#8192,d1
		bne.s	.l
		rts

; print one line per kernel: name, PTM ticks, checksum
report:
		lea	results(pc),a2
		lea	names(pc),a3
		moveq	#0,d4			; row
		moveq	#NKERN-1,d5
.l:		lea	line(pc),a0
		moveq	#8-1,d1
.n:		move.b	(a3)+,(a0)+
		dbra	d1,.n
		addq.l	#1,a3			; skip the NUL
		move.b	#'T',(a0)+
		move.b	#'=',(a0)+
		move.l	(a2)+,d0
		bsr	hex8
		move.b	#' ',(a0)+
		move.b	#'S',(a0)+
		move.b	#'=',(a0)+
		move.l	(a2)+,d0
		bsr	hex8
		clr.b	(a0)
		lea	line(pc),a0
		move.l	d4,d0
		addq.l	#2,d0
		jsr	ROM_PRINTLN
		addq.l	#1,d4
		dbra	d5,.l
		lea	donemsg(pc),a0
		move.l	d4,d0
		addq.l	#3,d0
		jsr	ROM_PRINTLN
		rts

; write d0 as 8 hex digits at a0 (advances a0)
hex8:
		moveq	#8-1,d2
.l:		rol.l	#4,d0
		move.b	d0,d3
		and.w	#$F,d3
		move.b	hexdig(pc,d3.w),(a0)+
		dbra	d2,.l
		rts
hexdig:		dc.b	"0123456789ABCDEF"

donemsg:	dc.b	"CPUBENCH DONE (T = PTM TICKS OF 4 US)",0
		even
line:		ds.b	48
results:	ds.l	2*NKERN

; 8 KB of straight-line code: 4096 x add.l d1,d7 (2 bytes each)
		cnop	0,16
icode:
		rept	4096
		add.l	d1,d7
		endr
		rts
