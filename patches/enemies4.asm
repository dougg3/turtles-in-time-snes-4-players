; Enemy code that only knew P1 and P2.
;
; $00:E7BC is called by twelve enemy/boss routines in bank $05 (and $00:E618): it
; returns A = number of players present (P1 if $0414, P2 if $0484 has a character)
; and $08/$0A = P1/P2 object or 0. Most callers only test "two players?" to pick
; a parameter set; $05:952D picks a target from $08/$0A at random; $05:C961 and
; $05:D277 award points ($04:81FB) to $08 and $0A.
; In 3P/4P: the count covers all four players, capped at 2 (enemy numbers and
; strength stay at the 2P values, PLAN section 9), $08/$0A = the first two present
; players; the random target is any present player; points go to every present
; player. 1P/2P: the original code.

!EnN        = $1CF4             ; players counted / loop index
!EnList     = $1CF6             ; 4 words: present players (RandomTarget4)

org $20C800
assert Extensions4End <= $20C800, "extensions4 code runs into enemies4"

; X = player index * 2 -> carry set if that player is present (as the original:
; its object has a character in +$14; P3/P4 also need their pointer). Keeps X, Y.
PlayerPresent:
    phy
    lda.l .slots,x : tay
    cpx #$0004 : bcc +
    lda.l .ptrs-4,x : tay
    lda $0000,y : tay
    beq .no
+   lda $0014,y : beq .no
    ply
    sec
    rtl
.no:
    ply
    clc
    rtl
.slots: dw !P1_slot, !P2_slot
.ptrs:  dw !P3_ptr, !P4_ptr

; ---- $00:E7BC (was STZ $08 / STZ $0A / ... / RTL) ----
PlayersPresent4:
    lda.l !PlayerMode : and #$00FF : cmp #$0003 : bcs .four
    stz $08 : stz $0A               ; original
    tdc
    ldy $0414 : beq +
    ldy #$0400 : sty $08
    inc
+   ldy $0484 : beq +
    ldy #$0470 : sty $0A
    inc
+   rtl
.four:
    phx
    stz $08 : stz $0A
    lda #$0000 : sta.l !EnN
    ldx #$0000
.loop:
    jsl PlayerPresent : bcc .next
    lda.l !EnN : bne +
    lda.l PlayerPresent_slots4,x : sta $08
    bra ++
+   cmp #$0001 : bne ++
    lda.l PlayerPresent_slots4,x : sta $0A
++  lda.l !EnN : inc : sta.l !EnN
.next:
    inx : inx
    cpx #$0008 : bcc .loop
    plx
    lda.l !EnN : cmp #$0003 : bcc +
    lda #$0002                      ; capped: 2P parameters
+   rtl

PlayerPresent_slots4: dw !P1_slot, !P2_slot, !P3_slot, !P4_slot

; ---- $05:9536 (target: was LDY $08 / BEQ / LDA $0A / BEQ / LDA $94 / BPL / LDY $0A;
; A = count from E7BC is non-zero here) -> Y = target ----
RandomTarget4:
    lda.l !PlayerMode : and #$00FF : cmp #$0003 : bcs .four
    ldy $08 : beq .p2               ; original
    lda $0A : beq .done
    lda $94 : bpl .done
.p2:
    ldy $0A
.done:
    rtl
.four:
    phx
    lda #$0000 : sta.l !EnN         ; list present players at !EnList
    ldx #$0000
-   jsl PlayerPresent : bcc +
    phx
    lda.l !EnN : asl : tay
    lda.l PlayerPresent_slots4,x
    tyx
    sta.l !EnList,x
    plx
    lda.l !EnN : inc : sta.l !EnN
+   inx : inx
    cpx #$0008 : bcc -
    lda $94 : and #$00FF            ; the game's random source
-   cmp.l !EnN : bcc +
    sec : sbc.l !EnN
    bra -
+   asl : tax
    lda.l !EnList,x : tay
    plx
    rtl

; ---- $05:C965 / $05:D27B (was LDY $08 / BEQ / JSL $0481FB / LDY $0A / BEQ /
; JSL $0481FB / RTL): points to every present player ----
PointsAll4:
    lda.l !PlayerMode : and #$00FF : cmp #$0003 : bcs .four
    ldy $08 : beq +                 ; original
    jsl $0481FB
+   ldy $0A : beq +
    jsl $0481FB
+   rtl
.four:
    lda #$0000
-   sta.l !EnN
    phx
    tax
    jsl PlayerPresent
    lda.l PlayerPresent_slots4,x : tay
    plx
    bcc +
    jsl $0481FB
+   lda.l !EnN : inc : inc
    cmp #$0008 : bcc -
    rtl

Enemies4End:
assert Enemies4End <= $20FFFF, "enemies4 code overflows bank $20"

; ---- hooks ----
org $00E7BC : jml PlayersPresent4   ; whole routine (28 bytes, ends RTL at $E7D7)
org $059536                         ; LDY $08 ... LDY $0A (14 bytes) -> Y = target
    jsl RandomTarget4
    nop #10
assert pc() == $059544
org $05C965 : jml PointsAll4        ; LDY $08 ... RTL (17 bytes)
org $05D27B : jml PointsAll4
