; Scene 8 (Neon Night-Riders, hoverboards; mode $16) for up to four players.
;
; The scene runs its own player loop ($04:918B: $919C for $9E and $A0) instead of
; the stage player update ($00:AD54), so P3/P4 were spawned but never run
; (object state 0: invisible, never hit). Here the loop also runs P3/P4.

org $20B400
assert Continue4End <= $20B400, "continue4 code runs into scene8"

; ---- $04:918B (was STZ $186A / LDY #0 / JSR $919C / LDY #2 / JSR $919C / RTL) ----
HoverPlayers4:
    stz $186A
    ldx $9E : beq +
    ldy #$0000 : jsl HoverTick
+   ldx $A0 : beq +
    ldy #$0002 : jsl HoverTick
+   lda.l !PlayerMode : and #$00FF : cmp #$0003 : bcc .done
    ldx !P3_ptr : beq +
    ldy #$0004 : jsl HoverTick
+   ldx !P4_ptr : beq .done
    ldy #$0006 : jsl HoverTick
.done:
    rtl

Scene8End:
assert Scene8End <= $20FFFF, "scene8 code overflows bank $20"

; ---- hooks ----
org $04918B                         ; 16 bytes up to the RTS at $919B (a branch target)
    jml HoverPlayers4
HoverTick:                          ; X = object, Y = index * 2: one player ($919C past
    jsr.w a16($0491A1)                       ; its pointer check)
    rtl
    nop #8
assert pc() == $04919B
