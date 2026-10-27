; Time-warp vortex (mode $19) with three or four players (user report 2026-10-25:
; with P1 and P4 out, the vortex showed only Mike although Raph, P3, was still in).
; The original counts P1/P2 ($9E/$A0) into $18F0 (two: two Mode 7 bands, split
; $18F2 = 1; one: a single band, $7F) and gives the bands P1's and P2's bandanas
; ($04:D06C -> $18F4/$18F6, $18F8/$18FA). P3/P4 were only copies of the two bands on
; the second Mode 7 layer (M7BFrame), so with P1 or P2 out (single band) they
; were never shown, and with only P3/P4 left nobody was.
; Now the players in the game, in order P1-P4, fill the bands: the first two the
; game's bands, the third and fourth the copies (M7BFrame). In 1P/2P games P3/P4's
; pointers are 0 and the result is the original's.

; RAM: !WarpN, !WarpList (ram.asm)

org $238000

; -> !WarpN, !WarpList (keeps registers)
WarpPlayers:
    php
    rep #$30
    phx
    ldx #$0000
    lda.l $00009E : beq +
    lda #$0000 : sta.l !WarpList,x : inx : inx
+   lda.l $0000A0 : beq +
    lda #$0002 : sta.l !WarpList,x : inx : inx
+   lda.l !P3_ptr : beq +
    lda #$0004 : sta.l !WarpList,x : inx : inx
+   lda.l !P4_ptr : beq +
    lda #$0006 : sta.l !WarpList,x : inx : inx
+   txa : lsr : sta.l !WarpN
    plx
    plp
    rtl

; ---- $04:C558 (was: $18F0 = P1 present + P2 present): players shown in the
; game's bands, at most two (A/X/Y 16-bit) ----
WarpCount:
    jsl WarpPlayers
    lda.l !WarpN : cmp #$0003 : bcc +
    lda #$0002
+   sta.l $0018F0
    rtl

; ---- $04:D06C (was the routine itself; returns with RTS there): the bands'
; bandana colors (10, 11): band 1 the first player shown, band 2 the second (one
; player: both bands his). 1P/2P: the original's rules exactly. ----
WarpColors:
    php
    rep #$30
    phx : phy
    lda.l !PlayerMode : and #$00FF : cmp #$0003 : bcs .four
    lda.l $000414 : beq .p2         ; the original ($04:D06C)
.one:
    jsr .band1
    lda.l $0018F0 : cmp #$0002 : beq .p2
.same:
    lda.l $0018F4 : sta.l $0018F8
    lda.l $0018F6 : sta.l $0018FA
    bra .done
.p2:
    lda.l $000484
    tay
    lda.l $0018F0 : cmp #$0002 : bne +
    tya : jsr .band2
    bra .done
+   tya
    bra .one
.four:
    lda.l !WarpN : beq .done        ; (nobody: nothing to show)
    lda.l !WarpList : jsr .char : jsr .band1
    lda.l !WarpN : cmp #$0002 : bcc .same
    lda.l !WarpList+2 : jsr .char : jsr .band2
.done:
    ply : plx
    plp
    rtl
; A = player index * 2 -> A = its character (2 Leo ... 8 Raph) from its info block
; (+$1A = turtle 0-3; the objects' +$14 are already cleared when the warp starts)
.char:
    tax
    lda.l WarpInfos,x : tax
    lda.l $00001A,x : and #$0003 : inc : asl
    rts
; A = character (2 Leo ... 8 Raph) -> band 1's / band 2's colors (the original's
; LDA $E16F,Y runs with DB = $01: the bandana table $01:E16F, 2 words per turtle)
.band1:
    beq +
    dec : dec : asl : tax
    lda.l $01E16F,x : sta.l $0018F4
    lda.l $01E171,x : sta.l $0018F6
+   rts
.band2:
    beq +
    dec : dec : asl : tax
    lda.l $01E16F,x : sta.l $0018F8
    lda.l $01E171,x : sta.l $0018FA
+   rts

WarpInfos:  dw !P1_info, !P2_info, !P3_info, !P4_info

Warp4End:
assert Warp4End <= $23FFFF, "warp4 code overflows bank $23"

; ---- hooks ----
Orig_C56B = $04C56B
org $04C558                         ; was STZ $18F0 / count $9E, $A0 (19 bytes)
    jsl WarpCount
    bra Orig_C56B
org $04D06C                         ; was the color routine (LDA $0414 / ...)
    jsl WarpColors
    rts
