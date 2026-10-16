; Soft-reboot test: a boot program that reboots the machine the way the
; BSD/HP-UX kernels do (caches off, a zero pushed, JMP to the ROM's
; REQ_REBOOT entry at $1A4) on its first run, and stops on its second.
; A RAM marker counts the runs; the LED latch shows $90 + run (the ROM's own
; LED countdowns use $Ax and $Bx).
; The ROM must load it again from the disk: keyboard, SCSI and all.
;
; Build: tools/rebootbench/build.sh

LED		equ	$0001FFFF
LOADADDR	equ	$FFF00000
MARK		equ	$FFE00000	; {magic, count}
MAXADDR		equ	$FFFFF000	; BSD: boothowto, bootdev

		org	LOADADDR
start:
		move.w	#$2700,sr
		lea	$FFFFFD00,sp
		lea	MARK,a0
		cmp.l	#$52425431,(a0)		; "RBT1"
		beq.s	.again
		move.l	#$52425431,(a0)
		clr.l	4(a0)
.again:		addq.l	#1,4(a0)
		move.l	4(a0),d0
		add.b	#$90,d0
		move.b	d0,LED
		cmp.l	#2,4(a0)
		bge.s	done
		; reboot (NetBSD hp300 locore DOREBOOT)
		clr.l	MAXADDR			; howto: RB_AUTOBOOT
		clr.l	MAXADDR+4
		moveq	#0,d0
		movec	d0,cacr
		moveq	#0,d0
		move.l	d0,-(sp)
		jmp	$1A4
done:		bra.s	done
