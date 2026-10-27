; Scene 5 warp-in: the turtle palette script with only P3/P4 left.
;
; $04:CA1D (mode $19, the time warp into Prehistoric Turtlesaurus) starts a palette
; script for one turtle: table $01:E167 indexed by P1's character ($0414), or P2's
; ($0484) when P1 is out. With P1 and P2 both out, the original can't get here (game
; over), but in 3P/4P P3/P4 go on: character 0 read the word before the table
; ($01:E165 = $70E0) as the script, and the stage started about a second early.
; Now 3P/4P with P1 and P2 out use P3's (or P4's) character. Slots 5/7 hold other
; data in mode $19, so the character comes from $D4/$D8, as for the stage start.

org $248100
assert Cheer4End <= $248100, "cheer4 runs into warpin4"

; ---- $04:CA2B (was LDA $0414 / BEQ $CA32 / BRA $CA35 / LDA $0484) -> A = character ----
WarpInChar4:
    lda.w !P1_slot+$14 : bne .done
    lda.w !P2_slot+$14 : bne .done
    jsl Scr4Mode : bcc .orig
    lda.w !P3_ptr : beq +
    lda.w !P3_char : bne .done
+   lda.w !P4_ptr : beq .orig
    lda.w !P4_char : bne .done
.orig:
    lda.w !P2_slot+$14              ; as the original (0)
.done:
    rtl

WarpIn4End:
assert WarpIn4End <= $24FFFF, "warpin4 code overflows bank $24"

Orig_CA35 = $04CA35
org $04CA2B
    jsl WarpInChar4
    bra Orig_CA35
