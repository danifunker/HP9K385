; A/UX 3.1 main(): copyout(icode, UVTEXT=0, szicode=$34) must survive the
; demand-zero fault on its first MOVES.  This copies A/UX's copyout routine
; (pstart $556f0..$557cc) instruction for instruction: the backwards
; longword loop "move.l -(a1),d1 / moves.l d1,-(a0)" entered through the
; same memory-indirect jump tables.  The kernel runs with SRP and URP
; distinct; the user page is invalid until the access-error handler makes it
; resident and RTEs.  hardflt040 refuses (copyout fails -> the panic) when
; the SSW says TM=5 with any of bits 15..10 set, so the SSW and FA the
; handler sees are the assertion.
;
; Fail codes ($F100):
;   1x  copyout returned nonzero / data wrong   (x = pass number)
;   2x  fault count != 1
;   3x  SSW != $0401 (ATC, write, long, TT0, TM1)
;   4x  FA  != $00000030
;   5x  a0 at copyout's exit wrong
;   15  unexpected exception

FAILREG         equ $F100
DONEREG         equ $F102

cnt_aerr        equ $3600
last_ssw        equ $3602
last_fa         equ $3604
last_pc         equ $3608
last_tm_bad     equ $360C
pass_no         equ $360E
first_ssw       equ $3610
first_fa        equ $3614

SRC             equ $6024           ; "icode", supervisor VA = PA
DSTPA           equ $A000           ; physical frame behind user page 0
UPTE            equ $4C00           ; user page table entry for VA 0
NBYTES          equ $34

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
; user: root $4800 -> pointer $4A00 -> page table $4C00, every page invalid
        lea     ($4800).l,a0
        move.w  #(($4D00-$4800)/4)-1,d1
uclr:   clr.l   (a0)+
        dbra    d1,uclr
        move.l  #$00004A03,($4800).l
        move.l  #$00004C03,($4A00).l

; "icode": 52 distinct bytes
        lea     (SRC).l,a0
        move.l  #$2E7C0000,d0
        moveq   #(NBYTES/4)-1,d1
sfill:  move.l  d0,(a0)+
        add.l   #$01030507,d0
        dbra    d1,sfill

        move.l  #$4000,d0
        movec   d0,srp
        move.l  #$4800,d0
        movec   d0,urp
        move.l  #$8000,d0               ; E=1, 4K pages
        movec   d0,tc
        pflusha
        moveq   #1,d0                   ; A/UX copies to user data
        movec   d0,dfc
        movec   d0,sfc

;------------------------------------------- pass 1: caches off
        move.w  #1,(pass_no).l
        moveq   #0,d0
        movec   d0,cacr
        bsr     one_pass

;------------------------------------------- pass 2: caches on, write-through
        move.w  #2,(pass_no).l
        move.l  #$00000808,d0
        movec   d0,cacr
        move.l  #$80008000,d0
        movec   d0,cacr
        bsr     one_pass

;------------------------------------------- pass 3: user page copyback
        move.w  #3,(pass_no).l
        move.l  #$00000023,(page_bits).l
        bsr     one_pass

;------------------------------------------- pass 4: source copyback too, hot
        move.w  #4,(pass_no).l
        move.l  #$00006023,($4400+4*6).l ; page 6 (SRC) copyback
        pflusha
        move.l  (SRC).l,d0               ; warm the source line
        bsr     one_pass

        moveq   #0,d0
        movec   d0,tc
        cpusha  dc
        movec   d0,cacr
        pflusha
        move.w  #$600D,(DONEREG).l
        stop    #$2700

;--------------------------------------------------------------------
; one copyout to an invalid user page 0, then check everything
one_pass:
        clr.l   (UPTE).l                ; user page 0 invalid again
        pflusha
        lea     (DSTPA).l,a0            ; clear the destination frame
        moveq   #(NBYTES/4)-1,d1
dclr:   clr.l   (a0)+
        dbra    d1,dclr
        cpusha  dc
        clr.w   (cnt_aerr).l
        clr.w   (last_ssw).l
        clr.l   (last_fa).l
        clr.l   (first_fa).l
        clr.w   (first_ssw).l

        pea     (NBYTES).w              ; count
        pea     (0).w                   ; to   (UVTEXT)
        pea     (SRC).l                 ; from (icode)
        jsr     copyout
        lea     12(sp),sp
        move.w  (pass_no).l,d7
        tst.l   d0
        bne     f_ret
        cmpa.l  #0,a0
        bne     f_a0
        cmpi.w  #1,(cnt_aerr).l
        bne     f_cnt
        cmpi.w  #$0401,(first_ssw).l
        bne     f_ssw
        cmpi.l  #$00000030,(first_fa).l
        bne     f_fa
        ; the data, read back through the user mapping and physically
        moveq   #(NBYTES/4)-1,d1
        lea     (SRC).l,a1
        suba.l  a2,a2
        lea     (DSTPA).l,a3
chkl:    moves.l (a2)+,d2
        cmp.l   (a1),d2
        bne     f_ret
        cpusha  dc
        move.l  (a3)+,d3
        cmp.l   (a1)+,d3
        bne     f_ret
        dbra    d1,chkl
        rts

page_bits:
        dc.l    $00000003

;--------------------------------------------------------------------
; A/UX copyout, pstart $556f0 (the u.u_caddrflt stores dropped)
copyout:
        movem.l 4(sp),d0/a0-a1
        exg     d0,a1
        cmpi.l  #$100,d0
        bge     u91                     ; p_copyout path not modelled
        moveq   #$e,d1
        adda.l  d0,a0
        adda.l  d0,a1
        subq.l  #4,d0
        blt     u92
        move.l  -(a1),d1
        moves.l d1,-(a0)
        move.l  a0,d1
        andi.l  #3,d1
        beq.b   co_al
        subq.l  #4,d1
        sub.l   d1,d0
        suba.l  d1,a0
        suba.l  d1,a1
co_al:  ror.l   #2,d0
        moveq   #$f,d1
        and.l   d0,d1
        lsr.l   #4,d0
        jmp     ([longtab,pc,d1.w*4])
bylong:
        rept    16
        move.l  -(a1),d1
        moves.l d1,-(a0)
        endr
        dbra    d0,bylong
        clr.w   d0
        rol.l   #6,d0
        jmp     ([bytetab,pc,d0.w*4])
bybyte:
        move.b  -(a1),d1
        moves.b d1,-(a0)
        move.b  -(a1),d1
        moves.b d1,-(a0)
        move.b  -(a1),d1
        moves.b d1,-(a0)
co_done:
        moveq   #0,d0
        rts

        cnop    0,4
longtab:
        dc.l    bylong+16*6, bylong+15*6, bylong+14*6, bylong+13*6
        dc.l    bylong+12*6, bylong+11*6, bylong+10*6, bylong+9*6
        dc.l    bylong+8*6,  bylong+7*6,  bylong+6*6,  bylong+5*6
        dc.l    bylong+4*6,  bylong+3*6,  bylong+2*6,  bylong+1*6
bytetab:
        dc.l    co_done, bybyte+12, bybyte+6, bybyte

;--------------------------------------------------------------------
; access error: A/UX's accerr/super_accerr shape (frame room, register save,
; CACR rewrite), then hardflt040's decision on the SSW, then repair + RTE.
h_aerr:
        suba.w  #$a,sp
        movem.l d0-d7/a0-a6,-(sp)
        movec   cacr,d2
        move.l  #$80008000,d0
        movec   d0,cacr
        cmpi.w  #$7008,$4c(sp)          ; format $7, vector 2
        bne     u93
        move.w  $52(sp),d0              ; SSW
        move.l  $5a(sp),d1              ; FA
        move.l  $48(sp),(last_pc).l
        move.w  d0,(last_ssw).l
        move.l  d1,(last_fa).l
        tst.w   (cnt_aerr).l
        bne.b   h_notfirst
        move.w  d0,(first_ssw).l
        move.l  d1,(first_fa).l
h_notfirst:
        addq.w  #1,(cnt_aerr).l
        cmpi.w  #8,(cnt_aerr).l
        bhi     u94                     ; a fault loop
        ; hardflt040: TM=5 with any of SSW[15:10] -> return -1 (copyout fails)
        move.w  d0,d3
        andi.w  #7,d3
        cmpi.w  #5,d3
        bne.b   h_user
        move.w  d0,d3
        andi.w  #$fc00,d3
        bne     h_refuse
h_user:
        move.l  #DSTPA,d3
        or.l    (page_bits).l,d3
        move.l  d3,(UPTE).l             ; vfault: page resident
        pflusha
        movec   d2,cacr
        movem.l (sp)+,d0-d7/a0-a6
        adda.w  #$a,sp
        rte
h_refuse:
        move.w  #1,(last_tm_bad).l
        move.w  (pass_no).l,d7
        add.w   #30,d7
        bra     fail

f_ret:  add.w   #10,d7
        bra     fail
f_cnt:  add.w   #20,d7
        bra     fail
f_ssw:  add.w   #30,d7
        bra     fail
f_fa:   add.w   #40,d7
        bra     fail
f_a0:   add.w   #50,d7
        bra     fail
u91:    move.w  #91,d7
        bra     fail
u92:    move.w  #92,d7
        bra     fail
u93:    move.w  #93,d7
        bra     fail
u94:    move.w  (last_ssw).l,(last_tm_bad).l
        move.w  #94,d7
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
