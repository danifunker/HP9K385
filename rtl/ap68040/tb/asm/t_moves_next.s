; The instruction AFTER a MOVES must run in its own space.
;
; MOVES selects its space with fc_ovr_v/fc_ovr, and those registers clear on
; the edge that retires the MOVES.  Anything the core issues for the next
; instruction on that same edge (the read-after-store handoff, a push, a
; pop) would still see them and go out in the MOVES space.  A/UX 3.1's
; copyout loop "move.l -(a1),d1 / moves.l d1,-(a0)" hit exactly that: the
; kernel's read of its own data went to user space (t_aux_copyout is that
; routine verbatim, with the page fault); this file is the catalogue of the
; other shapes the A/UX kernel and any other 68k Unix use:
;   copyout / copyin      moves next to (An) (An)+ -(An) d16(An) reads, stores
;   suword / fuword       moves, then clr.l / move to kernel memory
;   p_copyout / p_copyin  moves.b probe, then a push
;   moves, then bsr/jsr/pea/link/unlk/movem/rts/Bcc/dbra
;   moves, then a moves in the other space (SFC != DFC)
;
; Only user page 0 is mapped in the user tree (to physical $A000); every
; other user address is invalid.  So a kernel access that leaks into user
; space takes an access fault, and a MOVES that leaks into supervisor space
; lands on physical page 0 instead of $A000: each shape runs twice, once with
; MOVES against the user page and once with plain MOVE against a supervisor
; copy of the same data, and the registers and both memory images must match.
;
; Fail codes ($F100):
;   pass*100 + shape          result differs from the plain-MOVE reference
;   2000 + pass*100 + shape   access fault (SSW/FA/PC at $3602/$3604/$3608)
;   1000 + n                  unexpected vector n

FAILREG         equ $F100
DONEREG         equ $F102

cnt_aerr        equ $3600
last_ssw        equ $3602
last_fa         equ $3604
last_pc         equ $3608
pass_no         equ $360E
shape_no        equ $3610
scr_abs         equ $3618
res_t           equ $3620           ; d1-d4/a0-a2 after the MOVES run
res_r           equ $3640           ; ... after the reference run

KD              equ $6000           ; kernel data, read-only to the shapes
REF             equ $6100           ; supervisor copy of the user data
KS2             equ $6200           ; kernel-side output, MOVES run
KS3             equ $6300           ; kernel-side output, reference run
UB              equ $0100           ; user VA
UPA             equ $A100           ; the same bytes physically
UPTE            equ $4C00           ; user page table entry for VA 0

;--------------------------------------------------------------- the shapes
; \1 = moves (a0 -> user VA) or move (a0 -> REF)

; A/UX copyout: kernel -(An) read right after the MOVES store
m_copyout macro
        lea     32(a0),a0
        lea     32(a1),a1
        rept    8
        move.l  -(a1),d1
        \1.l    d1,-(a0)
        endr
        endm

; (An)+ word source
m_postinc macro
        rept    8
        move.w  (a1)+,d1
        \1.w    d1,(a0)+
        endr
        endm

; byte stores, (An) and d16(An) sources
m_bytes macro
        rept    4
        \1.b    d2,(a0)+
        move.b  (a1),d1
        \1.b    d1,(a0)+
        add.b   1(a1),d2
        addq.l  #2,a1
        endr
        endm

; ALU/TST/CMP with a memory source right after the store
m_alu   macro
        rept    3
        \1.l    d2,(a0)+
        add.l   (a1)+,d2
        \1.l    d2,(a0)+
        or.l    8(a1),d3
        \1.w    d3,(a0)+
        sub.w   -(a1),d4
        \1.w    d4,(a0)+
        tst.l   (a1)+
        smi     d1
        \1.b    d1,(a0)+
        cmp.w   (a1)+,d2
        scs     d1
        \1.b    d1,(a0)+
        addq.l  #2,a1
        endr
        endm

; kernel memory-to-memory, kernel stores (suword), the p_copyout probe + push
m_kstore macro
        rept    4
        \1.l    d2,(a0)+
        move.l  (a1)+,(a2)+
        \1.l    d1,(a0)+
        move.l  d2,(a2)+
        \1.w    d2,(a0)+
        clr.l   (a2)+
        \1.b    d2,(a0)+
        move.l  a1,-(a7)
        \1.b    d1,(a0)+
        move.l  (a7)+,d1
        move.l  #$12345678,(scr_abs).l
        \1.l    d1,(a0)+
        clr.l   (scr_abs).l
        or.l    (scr_abs).l,d3
        addq.l  #1,d2
        endr
        endm

; control transfers and stack traffic right after the store
m_calls macro
        lea     sub_inc(pc),a3
        \1.l    d2,(a0)+
        bsr.s   cs\@
        bra.s   cc\@
cs\@:   addq.l  #1,d2
        \1.l    d2,(a0)+
        rts
cc\@:   \1.l    d2,(a0)+
        bsr.w   sub_inc
        \1.l    d2,(a0)+
        jsr     (a3)
        \1.l    d2,(a0)+
        jsr     (sub_inc).l
        \1.l    d2,(a0)+
        jsr     sub_inc(pc)
        \1.l    d2,(a0)+
        pea     (a1)
        \1.l    d2,(a0)+
        pea     $10(a1)
        \1.l    d2,(a0)+
        pea     (sub_inc).l
        \1.l    d2,(a0)+
        move.l  (a7)+,d1
        \1.l    d1,(a0)+
        move.l  (a7)+,d3
        \1.l    d3,(a0)+
        add.l   (a7)+,d3
        \1.l    d3,(a0)+
        link    a6,#-8
        \1.l    d2,(a0)+
        unlk    a6
        \1.l    d2,(a0)+
        movem.l d1-d3,-(a7)
        \1.l    d2,(a0)+
        movem.l (a7)+,d1/d3-d4
        tst.l   d4                      ; same CCR for MOVE and MOVES
        \1.l    d4,(a0)+
        move.w  sr,-(a7)
        \1.w    d3,(a0)+
        move.w  (a7)+,d4
        \1.w    d4,(a0)+
        endm

; branches: not taken then a read, taken onto a read, the copyout loop's dbra.
; MOVE sets the condition codes and MOVES does not: the TST of the register
; about to be stored gives both runs the same flags.
m_branch macro
        tst.l   d2
        \1.l    d2,(a0)+
        beq.s   bn\@
        move.l  (a1)+,d1
bn\@:   tst.l   d1
        \1.l    d1,(a0)+
        bne.s   bt\@
        addq.l  #5,d2
bt\@:   add.l   (a1)+,d2
        \1.l    d2,(a0)+
        bra.s   bb\@
        addq.l  #7,d2
bb\@:   move.l  (a1)+,d3
        tst.l   d3
        \1.l    d3,(a0)+
        bne.w   bw\@
        addq.l  #3,d2
bw\@:   sub.l   (a1)+,d2
        moveq   #5,d4
bl\@:   move.l  (a1)+,d1
        \1.l    d1,(a0)+
        dbra    d4,bl\@
        moveq   #5,d4
bm\@:   \1.l    d1,(a0)+
        add.l   -(a1),d1
        dbra    d4,bm\@
        endm

; a store in one space, then a MOVES read of kernel data (SFC = 5, DFC = 1)
m_xread macro
        rept    6
        \1.l    d2,(a0)+
        \1.l    (a1)+,d2
        addq.l  #1,d2
        endr
        endm

; a MOVES read of user data, then a MOVES store to the kernel (SFC = 1, DFC = 5)
m_xwrite macro
        rept    6
        \1.l    (a0)+,d1
        \1.l    d1,(a2)+
        \1.w    (a0)+,d2
        \1.w    d2,(a2)+
        addq.l  #2,a0
        endr
        endm

; A/UX copyin: kernel store right after the MOVES read
m_copyin macro
        lea     32(a0),a0
        lea     32(a2),a2
        rept    8
        \1.l    -(a0),d1
        move.l  d1,-(a2)
        endr
        endm

; fuword, kernel reads after the user read, the p_copyin probe + push
m_fu    macro
        rept    4
        \1.l    (a0)+,d1
        move.l  (a1)+,d2
        add.l   d1,d2
        \1.w    (a0)+,d3
        add.w   (a1)+,d3
        \1.b    (a0)+,d4
        move.l  a1,-(a7)
        \1.b    (a0)+,d4
        add.l   (a7)+,d2
        move.l  #$12345678,(scr_abs).l
        \1.l    (a0)+,d1
        clr.l   (scr_abs).l
        or.l    (scr_abs).l,d3
        \1.l    (a0),d1
        move.l  d1,(a2)+
        \1.w    2(a0),d1
        cmp.w   (a1)+,d1
        scs     d4
        move.b  d4,(a2)+
        move.b  d3,(a2)+
        move.w  d2,(a2)+
        endr
        endm

; calls and pops right after the user read
m_fucall macro
        lea     sub_inc(pc),a3
        \1.l    (a0)+,d1
        bsr.s   fs\@
        bra.s   fc\@
fs\@:   add.l   d1,d2
        \1.l    (a0)+,d1
        rts
fc\@:   \1.l    (a0)+,d3
        jsr     (a3)
        \1.l    (a0)+,d3
        pea     (a1)
        \1.l    (a0)+,d4
        add.l   (a7)+,d4
        \1.l    (a0)+,d3
        link    a6,#-8
        \1.l    (a0)+,d3
        unlk    a6
        \1.l    (a0)+,d3
        movem.l d1-d3,-(a7)
        \1.l    (a0)+,d3
        movem.l (a7)+,d1/d3-d4
        tst.l   (REF+9*4).l             ; the flags MOVE will set from this read
        \1.l    (a0)+,d1
        bmi.s   fb\@
        add.l   (a1)+,d2
fb\@:   moveq   #5,d4
fl\@:   \1.l    (a0)+,d1
        add.l   (a1)+,d1
        move.l  d1,(a2)+
        dbra    d4,fl\@
        endm

;-------------------------------------------------------------- the driver
; \1 = shape number, \2 = shape macro.  -DONLY=n assembles shape n alone
; (to see every shape a given core fails, not just the first).
        ifnd    ONLY
ONLY    equ     0
        endif

shape   macro
        ifeq    ONLY*(ONLY-\1)
        move.w  #\1,(shape_no).l
        bsr     prep
        lea     (UB).w,a0
        lea     (KD).l,a1
        lea     (KS2).l,a2
        \2      moves
        nop
        suba.w  #UB,a0
        suba.l  #KS2,a2
        movem.l d1-d4/a0-a2,(res_t).l
        bsr     prep_regs
        lea     (REF).l,a0
        lea     (KD).l,a1
        lea     (KS3).l,a2
        \2      move
        nop
        suba.l  #REF,a0
        suba.l  #KS3,a2
        movem.l d1-d4/a0-a2,(res_r).l
        bsr     verify
        bne     sfail
        endif
        endm

        org     0
        dc.l    $3400,start
        dc.l    h_aerr                  ; vector 2: access fault
        rept    253
        dc.l    unexpected
        endr

        org     $400
start:
        move.w  #$2700,sr

;----------------------------------------------------------------- tables
; supervisor: identity, 64 pages, write-through
        lea     ($4400).l,a0
        moveq   #0,d0
        moveq   #63,d1
tloop:
        move.l  d0,d2
        lsl.l   #8,d2
        lsl.l   #4,d2                   ; i << 12
        addq.l  #3,d2                   ; resident
        move.l  d2,(a0)+
        addq.l  #1,d0
        dbra    d1,tloop
        move.l  #$00004203,($4000).l
        move.l  #$00004403,($4200).l
; user: root $4800 -> pointer $4A00 -> page table $4C00, only page 0 valid
        lea     ($4800).l,a0
        move.w  #(($4D00-$4800)/4)-1,d1
uclr:   clr.l   (a0)+
        dbra    d1,uclr
        move.l  #$00004A03,($4800).l
        move.l  #$00004C03,($4A00).l
        move.l  #$0000A003,(UPTE).l

        move.l  #$4000,d0
        movec   d0,srp
        move.l  #$4800,d0
        movec   d0,urp
        move.l  #$8000,d0               ; E=1, 4K pages
        movec   d0,tc
        pflusha
        moveq   #1,d0
        movec   d0,dfc
        movec   d0,sfc
        clr.w   (cnt_aerr).l

;------------------------------------------- pass 1: caches off
        move.w  #1,(pass_no).l
        moveq   #0,d0
        movec   d0,cacr
        bsr     all_shapes

;------------------------------------------- pass 2: caches on, write-through
        move.w  #2,(pass_no).l
        move.l  #$00000808,d0
        movec   d0,cacr
        move.l  #$80008000,d0
        movec   d0,cacr
        bsr     all_shapes

;------------------------------------------- pass 3: both pages copyback
        move.w  #3,(pass_no).l
        cpusha  dc
        move.l  #$0000A023,(UPTE).l
        move.l  #$00006023,($4400+4*6).l
        pflusha
        bsr     all_shapes

        moveq   #0,d0
        movec   d0,tc
        cpusha  dc
        movec   d0,cacr
        pflusha
        move.w  #$600D,(DONEREG).l
        stop    #$2700

;--------------------------------------------------------------------
all_shapes:
        shape   1,m_copyout
        shape   2,m_postinc
        shape   3,m_bytes
        shape   4,m_alu
        shape   5,m_kstore
        shape   6,m_calls
        shape   7,m_branch
        shape   8,m_copyin
        shape   9,m_fu
        shape   10,m_fucall
        ; MOVES in both spaces: user stores, kernel reads through SFC = 5
        moveq   #5,d0
        movec   d0,sfc
        shape   11,m_xread
        ; ... and user reads, kernel stores through DFC = 5
        moveq   #1,d0
        movec   d0,sfc
        moveq   #5,d0
        movec   d0,dfc
        shape   12,m_xwrite
        moveq   #1,d0
        movec   d0,dfc
        rts

sub_inc:
        addq.l  #1,d2
        rts

;--------------------------------------------------------------------
; fresh data for one shape: KD, the user frame and its supervisor copy,
; cleared kernel outputs, seeded registers
prep:
        lea     (KD).l,a0
        move.l  #$4B000001,d0
        moveq   #63,d1
p1:     move.l  d0,(a0)+
        add.l   #$01030507,d0
        dbra    d1,p1
        lea     (REF).l,a0
        lea     (UPA).l,a1
        move.l  #$55AA0001,d0
        moveq   #63,d1
p2:     move.l  d0,(a0)+
        move.l  d0,(a1)+
        add.l   #$07050301,d0
        dbra    d1,p2
        lea     (KS2).l,a0
        moveq   #127,d1
p3:     clr.l   (a0)+
        dbra    d1,p3
        clr.l   (scr_abs).l
        cpusha  dc
prep_regs:
        move.l  #$A1A10001,d1
        move.l  #$B2B20002,d2
        move.l  #$C3C30003,d3
        move.l  #$D4D40004,d4
        rts

; Z set when the MOVES run and the reference run agree
verify:
        cpusha  dc
        lea     (res_t).l,a3
        lea     (res_r).l,a4
        moveq   #6,d0
v1:     cmpm.l  (a3)+,(a4)+
        bne.b   vx
        dbra    d0,v1
        lea     (UPA).l,a3
        lea     (REF).l,a4
        moveq   #63,d0
v2:     cmpm.l  (a3)+,(a4)+
        bne.b   vx
        dbra    d0,v2
        lea     (KS2).l,a3
        lea     (KS3).l,a4
        moveq   #63,d0
v3:     cmpm.l  (a3)+,(a4)+
        bne.b   vx
        dbra    d0,v3
        moveq   #0,d0
vx:     rts

;--------------------------------------------------------------------
; no access fault is legitimate here
h_aerr:
        move.w  $c(sp),(last_ssw).l
        move.l  $14(sp),(last_fa).l
        move.l  2(sp),(last_pc).l
        addq.w  #1,(cnt_aerr).l
        move.w  (pass_no).l,d7
        mulu.w  #100,d7
        add.w   (shape_no).l,d7
        add.w   #2000,d7
        bra     fail

sfail:
        move.w  (pass_no).l,d7
        mulu.w  #100,d7
        add.w   (shape_no).l,d7
        bra     fail
unexpected:
        move.w  6(sp),d7                ; format/vector word
        andi.w  #$0fff,d7
        lsr.w   #2,d7
        add.w   #1000,d7                ; 1000 + vector number
fail:
        move.w  d7,(FAILREG).l
        move.w  #$BAD0,(DONEREG).l
halt:
        bra     halt
