; Full-screen continue (mode $0E, $00:AAC2) for up to four players.
;
; The screen comes up when the last player in the game runs out of lives while
; someone still has credits; that player's box says CONT and START continues
; (info state $0A). The original lets P1 continue, and P2 in a 2-player game. Here
; P3/P4 can as well, if they joined this game (!SelSession). A continue takes a
; credit from everyone in the game, as the original does for P1 and P2; whoever is
; left with credits >= 0 chooses a turtle next (select4.asm), the others stay out
; until they join again with START in the stage.

org $20B000
assert Select4End <= $20B000, "select4 code runs into continue4"

; ---- $04:D65A (info state 7 on the continue screen, X = info; was CPX #$1A80 /
; BEQ $D664 / LDA $00E0 / BEQ $D66A): may this player continue? ----
ContOffer4:
    cpx.w #!P1_info : beq .yes
    cpx.w #!P2_info : bne .p34
    lda.w $00E0 : beq .no
.yes:
    jml $04D664                     ; state 9: CONT
.p34:
    lda #$0004
    cpx.w #!P3_info : beq +
    lda #$0008
+   and.l !SelSession : bne .yes
.no:
    jml $04D66A

; ---- $00:AB86 (continue screen, after P1's check; was LDA $1AC0 / CMP #$000A /
; BNE $AB95 / LDA $2A / BIT #$1000 / BNE $ABB5): START from P2-P4 ----
ContStart4:
    lda.w !P2_info : cmp #$000A : bne +
    lda $2A : bit #$1000 : bne .go
+   lda.w !P3_info : cmp #$000A : bne +
    lda $2C : bit #$1000 : bne .go
+   lda.w !P4_info : cmp #$000A : bne +
    lda $2E : bit #$1000 : bne .go
+   jml $00AB95
.go:
    jml $00ABB5

; ---- $00:ABBC (continue chosen; was LDA $E0 / BEQ $ABC7 / DEC $1ACE / DEC $1A8E /
; RTL): one credit from everyone in the game ----
ContCredits4:
    lda $E0 : beq +
    dec.w !P2_info+$0E
+   dec.w !P1_info+$0E
    lda.l !SelSession : and #$0004 : beq +
    dec.w !P3_info+$0E
+   lda.l !SelSession : and #$0008 : beq +
    dec.w !P4_info+$0E
+   rtl

Continue4End:
assert Continue4End <= $20FFFF, "continue4 code overflows bank $20"

; ---- hooks ----
org $04D65A                         ; was CPX #$1A80 / BEQ / LDA $00E0 / BEQ (10 bytes)
    jml ContOffer4
    nop #6
org $00AB86                         ; was LDA $1AC0 / ... / BNE $ABB5 (15 bytes)
    jml ContStart4
    nop #11
org $00ABBC                         ; was LDA $E0 / BEQ / DEC $1ACE / DEC $1A8E / RTL
    jml ContCredits4
