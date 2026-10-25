; Extension unit test ROM. Standalone 32 KB LoROM, no game data.
; Assemble with -DCTRL=1 (extended sprites) or -DCTRL=3 (and raised per-line
; limits); scripts/test_extensions.sh checks the screenshot pixels.
;
; Backdrop: blue if the extension ID reads "S+" ($21CE/$21CF), else black (then no
; extension is switched on). Sprites are 8x8; normal tile 1 is color 1, extra
; tile 1 is color 2. OBJ palette 0: 1 red, 2 white; extra palette 8: 1 yellow,
; 2 green.
;   row y=16: x=16 entry 0 (red); x=48 ext entry 128, page+bank (green);
;             x=80 ext 129, bank only (yellow); x=112 ext 130, page only (white)
;   row y=48: entry 1 at x=16 (red) over ext entry 131 at x=20 (green): the lower
;             entry wins, x=20-23 red, x=24-27 green
;   row y=80: entries 2-33 at x=0,6,...,186 and ext entries 132-139 at
;             x=200,...,242: 40 sprites on one line; x=244 is drawn only with the
;             raised limits (128 sprites), the plain limit keeps the first 32
;             (all normal entries).
lorom
if not(defined("CTRL"))
    !CTRL = 1
endif

org $008000
Reset:
    sei : clc : xce
    rep #$38
    ldx #$1FFF : txs
    sep #$20
    lda #$80 : sta $2100            ; forced blank
    stz $4200
    stz $2101                       ; OBJ 8x8/16x16, tiles at VRAM $0000
    lda #$01 : sta $2105
    lda #$10 : sta $212C            ; OBJ only
    stz $212D : stz $2130 : stz $2131

    ; OAM: everything off screen
    stz $2102 : stz $2103
    ldx #$0080
-   stz $2104 : lda #$F0 : sta $2104 : stz $2104 : stz $2104
    dex : bne -
    ldx #$0020
-   stz $2104
    dex : bne -

    ; VRAM tile 1 (word $0010): color 1 (plane 0)
    lda #$80 : sta $2115
    ldx #$0010 : stx $2116
    ldx #$0008
-   lda #$FF : sta $2118 : stz $2119
    dex : bne -
    ldx #$0008
-   stz $2118 : stz $2119
    dex : bne -

    ; CGRAM: backdrop black, OBJ palette 0 colors 1 red, 2 white
    stz $2121 : stz $2122 : stz $2122
    lda #129 : sta $2121
    lda #$1F : sta $2122 : stz $2122
    lda #$FF : sta $2122 : lda #$7F : sta $2122

    ; normal OAM entries: table of entry, x, y
    ldy #$0000
-   lda.w NormalTable,y : cmp #$FF : beq +
    asl : sta $2102 : stz $2103
    lda.w NormalTable+1,y : sta $2104   ; x
    lda.w NormalTable+2,y : sta $2104   ; y
    lda #$01 : sta $2104                ; tile 1
    lda #$30 : sta $2104                ; priority 3, palette 0
    iny #3
    bra -
+

    ; extensions present?
    lda $21CE : cmp #'S' : beq +
    jmp .done
+   lda $21CF : cmp #'+' : beq +
    jmp .done
+
    stz $2121 : stz $2122 : lda #$7C : sta $2122   ; backdrop blue

    ; extended OAM ($4000): all 128 entries off screen
    ldx #$4000 : jsr PortAddr
    ldx #$0080
-   stz $21C2 : lda #$F0 : sta $21C2 : stz $21C2 : stz $21C2
    dex : bne -
    ldx #$0020
-   stz $21C2
    dex : bne -
    ; extended attributes ($4300): all 0
    ldx #$4300 : jsr PortAddr
    ldx #$0040
-   stz $21C2
    dex : bne -
    ; extra tile 1 ($0020): color 2 (plane 1)
    ldx #$0020 : jsr PortAddr
    ldx #$0008
-   stz $21C2 : lda #$FF : sta $21C2
    dex : bne -
    ldx #$0010
-   stz $21C2
    dex : bne -
    ; extra palette 8 ($4400): colors 1 yellow, 2 green
    ldx #$4402 : jsr PortAddr
    lda #$FF : sta $21C2 : lda #$03 : sta $21C2
    lda #$E0 : sta $21C2 : lda #$03 : sta $21C2

    ; extended entries: entry, x, y, attribute bits (bit 0 page, bit 1 bank)
    ldy #$0000
-   lda.w ExtTable,y : cmp #$FF : beq +
    rep #$20
    and #$007F : asl #2 : clc : adc #$4000 : tax
    sep #$20
    jsr PortAddr
    lda.w ExtTable+1,y : sta $21C2
    lda.w ExtTable+2,y : sta $21C2
    lda #$01 : sta $21C2
    lda #$30 : sta $21C2
    lda.w ExtTable,y                ; attribute byte $4300 + entry / 4 (read-modify-write)
    rep #$20
    and #$00FF : lsr #2 : clc : adc #$4300 : tax
    sep #$20
    jsr PortAddr
    lda $21C3 : sta $00
    jsr PortAddr
    lda.w ExtTable,y
    rep #$20 : and #$0003 : asl : tax : sep #$20   ; shift = (entry & 3) * 2
    lda.w ExtTable+3,y
-- cpx #$0000 : beq ++
    asl
    dex
    bra --
++  ora $00 : sta $21C2
    iny #4
    bra -
+
    lda #!CTRL : sta $21C4
.done:
    lda #$0F : sta $2100
Forever:
    bra Forever

PortAddr:                           ; X = port address
    phx
    rep #$20 : txa : sep #$20
    sta $21C0 : xba : sta $21C1
    plx
    rts

NormalTable:
    db 0, 16, 16
    db 1, 16, 48
    !i = 0
    while !i < 32
        db 2+!i, (!i*6), 80
        !i #= !i+1
    endwhile
    db $FF
ExtTable:
    db 128, 48, 16, 3
    db 129, 80, 16, 2
    db 130, 112, 16, 1
    db 131, 20, 48, 3
    !i = 0
    while !i < 8
        db 132+!i, 200+(!i*6), 80, 0
        !i #= !i+1
    endwhile
    db $FF

Nmi:
    rti

org $00FFC0
    db "EXTENSION TEST       "
    db $20, $00, $05, $00, $01, $33, $00
    dw $0000, $FFFF
org $00FFE4
    dw Nmi, Nmi, Nmi, Nmi, Nmi, Nmi
org $00FFF4
    dw Nmi, Nmi, Nmi, Nmi, Reset, Nmi
