; P3/P4 live in pool slots 5/7, which the original leaves free during play
; but uses for its own objects on the turtle select screen and in the cutscene
; after Scene 8 ($04:D171). Code that treats slots 5/7 as players asks
; P34Live first, so those objects keep their original handling (also in 1P/2P).

org $20B800
assert Scene8End <= $20B800, "scene8 code runs into slots4"

; X = object -> carry set if X is the P3/P4 player object: 3P/4P mode, its pointer
; set, and a game mode with players on screen. Keeps X, Y.
P34Live:
    cpx.w #!P3_slot : bne +
    lda.l !P3_ptr
    bra .ptr
+   cpx.w #!P4_slot : bne .no
    lda.l !P4_ptr
.ptr:
    beq .no
    lda.l !PlayerMode : and #$00FF : cmp #$0003 : bcc .no
    phx
    lda.l $000070 : and #$001F : tax
    lda.l LiveModes,x
    plx
    lsr                             ; bit 0 -> carry
    rtl
.no:
    clc
    rtl

; modes with player objects: $0A stage, $0B stage clear, $0C stage intro, $10-$18
; (stage variants; $16/$17 Scene 8 hoverboards)
LiveModes:
    db 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0
    db 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0

; ---- $04:860C (via Clear56, bank $00): STZ $0456 / STZ $04C6 (P1/P2 +$56), and P3/P4
; and their companions ----
Clear56Far:
    stz $0456 : stz $04C6
    lda.l !PlayerMode : and #$00FF : cmp #$0003 : bcc .done
    phx
    ldx.w #!P3_slot : jsl P34Live : bcc + : stz $56,x
+   ldx.w #!P4_slot : jsl P34Live : bcc + : stz $56,x
+   plx
    stz !P3_compA+$4E : stz !P4_compA+$4E
    stz !P3_compB+$4E : stz !P4_compB+$4E
.done:
    rtl

Slots4End:
assert Slots4End <= $20FFFF, "slots4 code overflows bank $20"
