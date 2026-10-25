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

; ---- enemy grabs: the original maps player index <-> object with "P1 or else
; P2"; P3/P4 got P2's object/index, so a grab could flag one player and hold
; another (P1 found waiting for ever in state $1A for a release that never came) ----
; Y = player index * 2 -> A = player object. Keeps X, Y.
SlotAfromY:
    phx
    tyx
    lda.l .slots,x
    plx
    rtl
.slots: dw !P1_slot, !P2_slot, !P3_slot, !P4_slot

; $04:81CF (traps, e.g. Scene 6's planks, $03:E000; was DEY / BNE / LDY #$0400 / RTL /
; LDY #$0470 / RTL): Y = player index * 2 + 1 -> Y = player object. Keeps A, X.
SlotYfromIndex1:
    pha
    dey
    jsl SlotAfromY
    tay
    pla
    rtl

Slots4End:
assert Slots4End <= $20FFFF, "slots4 code overflows bank $20"

; $03:C418 (grab: held object from the enemy's +$34 = player index * 2 + 1; was
; LDA #$0400 / DEY / BEQ $C421 / LDA #$0470)
org $03C418
    dey
    jsl SlotAfromY
    nop #4
assert pc() == $03C421
; $04:8298 (grab check: player index from object X; was LDY #0 / CPX #$0400 / BEQ /
; INY / INY)
org $048298
    jsl IndexYfromX
    nop #6
assert pc() == $0482A2
org $0481CF : jml SlotYfromIndex1   ; was DEY / BNE $81D6 / LDY #$0400 / RTL / ...

; Scene 6 plank trap, state 3 ($03:B166): the held player from +$5E = player
; index * 2 + 1 (was LDY #$0400 / DEC A / BEQ / LDY #$0470), and the release, which
; addressed the per-player word array one byte low ($19DB,Y; the relocation
; repointed only the $19DC operands): the struck turtle waited for ever in state $1A.
org $03B16A
    tay
    jsl SlotYfromIndex1
    nop #4
assert pc() == $03B173
org $03B199+1 : dw !PlayerWordArray-1   ; STA $19DB,Y
