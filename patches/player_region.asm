; Player-region loops for P3/P4.
;
; The engine keeps the players and their companions in slots 0-7 ("player region",
; $0400-$077F) and processes them with dedicated loops; the generic object loop
; ($03:80D5) starts at slot 8. P3/P4 mains sit in slots 5/7 (inside the region);
; their companions live outside the object pool (ram.asm), so no enemy slot is
; given up. In 3P/4P mode:
;   - the companion-A/B loops must not run companion handlers on slots 5/7, and
;     must also process the P3/P4 companion objects;
;   - the scroll-shift loops, the +$4E/+$56 clears, the pool clear, the sprite
;     priority passes and the draw loops must also cover them.
; 1P/2P: every helper reduces to the original behavior.

Orig_CompBObject  = $00C45F     ; per-object routine of the companion-B loop
Orig_CompAObject  = $00C524     ; per-object routine of the companion-A loop
Orig_ShiftClamp   = $00C79B     ; used by the scroll-shift loop ($00:EE89)
Orig_Shift2_EEC4  = $00EEC4     ; bodies of the second shift loop ($00:EEB2/EEB5)
Orig_Shift2_EEDD  = $00EEDD

org $00FE70
assert Players4End <= $00FE70, "players4 code runs into player_region code"

; X = object; Z set (and returns) if X is the P3/P4 player object (slots4.asm).
IsP34Main:
    jsl P34Live : bcc +
    lda #$0000                      ; Z = 1: skip
    rts
+   lda #$0001                      ; Z = 0
    rts

; ---- companion-B loop ($00:C448, slots 4-7) ----
CompBStep:                          ; was JSL $00C45F
    jsr IsP34Main : beq +
    jml Orig_CompBObject
+   rtl
CompBExit:                          ; was CPX #$0780 (JSR; BCC loop / RTL kept)
    cpx #$0780 : bcc .ret
    jsr IsMode34 : bcc .done
    phx
    ldx.w #!P3_compB : lda $14,x : beq + : jsl Orig_CompBObject
+   ldx.w #!P4_compB : lda $14,x : beq + : jsl Orig_CompBObject
+   plx
.done:
    sec                             ; loop finished
.ret:
    rts

; ---- companion-A loop ($00:C50D, slots 2-7) ----
; Slots 2-7 hold both companions (A: slots 2/3, B: slots 4/6), so this loop is what
; runs P1's/P2's companion B (attack objects, portal effects, boards) in play; the
; companion-B loop ($00:C448) is rarely used. P3/P4 companion B too.
CompAStep:                          ; was JSL $00C524
    jsr IsP34Main : beq +
    jml Orig_CompAObject
+   rtl
CompAExit:
    cpx #$0780 : bcc .ret
    jsr IsMode34 : bcc .done
    phx
    ldx.w #!P3_compA : lda $14,x : beq + : jsl Orig_CompAObject
+   ldx.w #!P4_compA : lda $14,x : beq + : jsl Orig_CompAObject
+   ldx.w #!P3_compB : lda $14,x : beq + : jsl Orig_CompAObject
+   ldx.w #!P4_compB : lda $14,x : beq + : jsl Orig_CompAObject
+   plx
.done:
    sec
.ret:
    rts

; ---- scroll shift ($00:EE74 loop, slots 0-7): same body for P3/P4 companions ----
ShiftExit:
    cpx #$0780 : bcc .ret
    jsr IsMode34 : bcc .done
    phx
    ldx.w #!P3_compA : jsr .one
    ldx.w #!P4_compA : jsr .one
    ldx.w #!P3_compB : jsr .one
    ldx.w #!P4_compB : jsr .one
    plx
.done:
    sec
.ret:
    rts
.one:                               ; as $00:EE7F-$EE95
    lda $14,x : beq +
    lda $08,x : sec : sbc $17AA
    jsl Orig_ShiftClamp
    sta $08,x
    lda $0C,x : sec : sbc $17BA
    sta $0C,x
+   rts

; ---- second shift loop ($00:EEA3, slots 0-7): JSR $EEC4 / JSR $EEDD per object ----
Shift2Exit:
    cpx #$0780 : bcc .ret
    jsr IsMode34 : bcc .done
    phx
    ldx.w #!P3_compA : jsr .one
    ldx.w #!P4_compA : jsr .one
    ldx.w #!P3_compB : jsr .one
    ldx.w #!P4_compB : jsr .one
    plx
.done:
    sec
.ret:
    rts
.one:
    lda $14,x : beq +
    jsr Orig_Shift2_EEC4&$FFFF
    jsr Orig_Shift2_EEDD&$FFFF
+   rts

; carry set if 3P/4P mode
IsMode34:
    lda !PlayerMode : and #$00FF : cmp #$0003
    rts
Prio0Stub:
    jsl Prio0Extra
    rts
PlayerRegionEnd:
assert PlayerRegionEnd <= $00FFB0, "player_region code overflows bank $00 padding"

; ---- $04:85F8 loop end: STZ $0456 / STZ $04C6 (P1/P2 +$56) -> also P3/P4 ----
org $00FBF2
assert PlayerHelpersEnd <= $00FBF2, "player helpers run into IsP1SideMain"
; $00:B6F8 (companion effect frames: P1's set, else P2's; was CPX #$0400): Z set for
; P1 and P3 (P3 draws from P1's tile numbers and palette, P4 from P2's)
IsP1SideMain:
    cpx #!P1_slot : beq +
    cpx #!P3_slot
+   rts
assert pc() <= $00FBFC
org $00FBFC
Clear56:
    jml Clear56Far
Clear56End:
assert Clear56End <= $00FC00, "Clear56 overflows its gap (players4 code at $00:FC00)"

; ---- bank 3 stub for the $03:8730 priority pass ----
org $03FF70
assert EnemyHitsEnd <= $03FF70, "bank 03 helpers overlap"
Prio3Stub:
    jsl Prio3Extra
    rts
Bank3StubEnd:
assert Bank3StubEnd <= $03FFF0, "bank 03 padding overflow"

; ---- hooks ----
org $00C44F : jsl CompBStep                 ; was JSL $00C45F
org $00C459 : jsr CompBExit                 ; was CPX #$0780 (BCC $C44B / RTL follow)
org $00C514 : jsl CompAStep                 ; was JSL $00C524
org $00C51E : jsr CompAExit                 ; was CPX #$0780
org $00EE9D : jsr ShiftExit                 ; was CPX #$0780
org $00EEBE : jsr Shift2Exit                ; was CPX #$0780
org $04860C                                 ; was STZ $0456 / STZ $04C6
    jsl Clear56
    nop : nop

; ======== bank 5: pool-wide loops that must also see the P3/P4 companions ========
; Hot loops (OAM builder, draw-order list) keep their original per-object code:
; the companions are handled once at loop start (cost in 1P/2P: one JSL + mode test).
Orig_DrawObject  = $0092FB      ; OAM builder per-object routine (carry set = OAM full)
Orig_OamFull     = $0091FD      ; OAM builder exit taken when OAM is full (REP / PLB / RTL)
Orig_VShiftLoop  = $029C3A

org $05F88B
; ---- OAM builder, unsorted path ($00:91AC, was LDX #$0400 / CLC): draw the P3/P4
; companions first, like the other player-region objects (slots 0-7 come first too) ----
OamExtras:
    lda.l !PlayerMode : and #$00FF : cmp #$0003 : bcc .done
    ldx.w #!P3_compA : jsr .one : bcs .full
    ldx.w #!P4_compA : jsr .one : bcs .full
    ldx.w #!P3_compB : jsr .one : bcs .full
    ldx.w #!P4_compB : jsr .one : bcs .full
.done:
    ldx #$0400
    clc
    rtl
.one:                               ; as $00:91B0-$91BA
    stx $FC
    ldy $00,x : beq +
    jsl Orig_DrawObject
    rts
+   clc
    rts
.full:                              ; as BCS $91FD: drop our return address, take the exit
    rep #$20
    pla
    sep #$20
    pla
    rep #$20
    jml Orig_OamFull

; ---- draw-order list ($00:94FC, was LDX #$16C0 / LDY #$0400): list the P3/P4
; companions too (the list has room for 48 objects; the pool has 38) ----
ListExtras:
    ldx #$16C0
    lda.l !PlayerMode : and #$00FF : cmp #$0003 : bcc .done
    ldy.w #!P3_compA : jsr .one
    ldy.w #!P4_compA : jsr .one
    ldy.w #!P3_compB : jsr .one
    ldy.w #!P4_compB : jsr .one
.done:
    ldy #$0400
    rtl
.one:                               ; as $00:9502-$950F
    lda $0000,y : beq +
    sty $00,x
    lda $0012,y : sta $60,x
    inx : inx
+   rts

; A = current object; returns A = next object, carry clear = continue, carry set = done.
; Order: pool slots 0-37, then (3P/4P only) P3/P4 companion A, then companion B.
; (Only used by the rarely run vertical-shift loop $02:9C37.)
NextObjL:
    cmp.w #!P3_compA : beq .p4a
    cmp.w #!P4_compA : beq .p3b
    cmp.w #!P3_compB : beq .p4b
    cmp.w #!P4_compB : beq .end
    clc : adc #$0070
    cmp #$14A0 : bcc .ret
    lda.l !PlayerMode : and #$00FF : cmp #$0003 : bcc .end
    lda.w #!P3_compA : clc : rtl
.p4a:
    lda.w #!P4_compA : clc : rtl
.p3b:
    lda.w #!P3_compB : clc : rtl
.p4b:
    lda.w #!P4_compB : clc : rtl
.end:
    sec
.ret:
    rtl
; ---- $00:8870 pool clear (MVN $0400-$149E): also clear the P3/P4 companions ----
ClearExtras:                        ; was STA $000400 (A = 0)
    sta.l $000400
    lda.l !PlayerMode : and #$00FF : cmp #$0003 : bcc .done
    ldx #$006E
-   lda #$0000
    sta.l !P3_compA,x : sta.l !P4_compA,x
    sta.l !P3_compB,x : sta.l !P4_compB,x
    dex : dex : bpl -
.done:
    lda #$0000
    rtl

; ---- sprite priority passes ($00:9633 and $03:8730): +$04 priority bits by
; depth against $00. They list P1/P2 and their companions explicitly, then loop
; over slots 9-39. The loop start LDX #$08D0 is replaced by a JSR to a same-bank
; stub (the loop branches back to the JSR <per-object> right after it); adds P3/P4
; mains and companions, then returns X = $08D0 as the original. ----
Prio0Extra:
    lda.l !PlayerMode : and #$00FF : cmp #$0003 : bcc .slot9
    ldx.w #!P3_slot : jsr .main
    ldx.w #!P4_slot : jsr .main
    ldx.w #!P3_compB : jsr .obj
    ldx.w #!P4_compB : jsr .obj
    ldx.w #!P3_compA : jsr .compA
    ldx.w #!P4_compA : jsr .compA
.slot9:
    ldx #$08D0
    rtl
.main:
    jsl P34Live : bcs .obj
    rts
.obj:                               ; as $00:96A1
    lda $14,x : beq +
    lda $12,x : cmp $00
    lda $04,x : and #$6767
    bcs ++
    ora #$0888
++  sta $04,x
+   rts
.compA:                             ; as $00:9660-$966F
    lda $14,x : beq +
    lda $04,x : and #$6767 : ora #$0888 : sta $04,x
+   rts

Prio3Extra:
    lda.l !PlayerMode : and #$00FF : cmp #$0003 : bcc .slot9
    ldx.w #!P3_slot : jsr .main
    ldx.w #!P4_slot : jsr .main
    ldx.w #!P3_compB : jsr .obj
    ldx.w #!P4_compB : jsr .obj
    ldx.w #!P3_compA : jsr .compA
    ldx.w #!P4_compA : jsr .compA
.slot9:
    ldx #$08D0
    rtl
.compA:                             ; as $03:8790
    lda $12,x : bne .obj
    lda $0C,x : bra .cmp
.main:
    jsl P34Live : bcs .obj
    rts
.obj:                               ; as $03:8798
    lda $14,x : beq +
    lda $12,x
.cmp:
    cmp $00
    lda $04,x : and #$6767
    bcs ++
    ora #$1090
++  sta $04,x
+   rts
Bank5End:
assert Bank5End <= $060000, "bank 5 free space overflow"

; ---- pool-walk hooks ----
org $0091AC : jsl OamExtras         ; was LDX #$0400 / CLC
org $0094FC                         ; was LDX #$16C0 / LDY #$0400
    jsl ListExtras
    nop : nop
org $029C4D                         ; vertical shift of all objects: TXA / CLC / ADC / TAX / CMP / BCC
    txa
    jsl NextObjL
    tax
    bcc Orig_VShiftLoop
    nop : nop : nop
org $008876 : jsl ClearExtras       ; was STA $000400
org $00964F : jsr Prio0Stub        ; was LDX #$08D0
org $038760 : jsr Prio3Stub        ; was LDX #$08D0
org $00B6F8 : jsr IsP1SideMain      ; was CPX #$0400 (BNE $B70B follows)
