; Title menu: "2-4 PLAYERS" when a multitap is on port 2.
;
; $04:B0CE draws the menu with the string drawer $00:9779 (X = string in the data
; bank, $01): [tilemap word][characters] $FF, $FE = next [word][character]. Strings:
; $85BD "1 PLAYER" (row 19, column 7), $85C8 "2 PLAYERS" (row 21), $85D4 "VERSUS"
; (row 21, column 18), $85DD "TIME TRIAL" (row 19, column 18), $85EA "OPTION" (row
; 23), $85F3 the copyright lines, then cursor set $861A. On a move $04:B05E picks a
; cursor set by the item ($56: 0 1P, 1 2P, 2 OPTION, 3 TIME TRIAL, 4 VERSUS), each
; drawing the cursor (character $F6) at one of five places and blanks at the others.
; After START, $00:8564 flashes the chosen item: its string by $56, blanked on
; alternate frames ($F0).
; Characters: ASCII - $31, digit n = n + 1, space 0, "-" $2B.
;
; With a multitap the left column starts one column further left (column 6) so
; "2-4 PLAYERS" fits, and the right column one further right (column 19), keeping
; the original two-column gap; the cursor places move with them. Without a
; multitap the original strings and cursor sets are drawn, unchanged.

Orig_DrawString = $009779

org $20E000
assert Scripts4End <= $20E000, "scripts4 code runs into title4"

; $04:B0CE (was the seven LDX/JSL $009779 calls and RTS; A/X 16-bit, DB = $01)
TitleText4:
    jsr DetectMultitap : bcs .four
    ldx #a16($0185BD) : jsl Orig_DrawString
    ldx #a16($0185C8) : jsl Orig_DrawString
    ldx #a16($0185D4) : jsl Orig_DrawString
    ldx #a16($0185DD) : jsl Orig_DrawString
    ldx #a16($0185EA) : jsl Orig_DrawString
    ldx #a16($0185F3) : jsl Orig_DrawString
    ldx #a16($01861A) : jsl Orig_DrawString
    rtl
.four:
    ldx #a16($0185F3) : jsl Orig_DrawString    ; copyright lines (bank $01)
    phb : phk : plb
    ldx.w #T4OnePlayer : jsl Orig_DrawString
    ldx.w #T4Players : jsl Orig_DrawString
    ldx.w #T4Versus : jsl Orig_DrawString
    ldx.w #T4TimeTrial : jsl Orig_DrawString
    ldx.w #T4Option : jsl Orig_DrawString
    ldx.w #T4Cursor0 : jsl Orig_DrawString
    plb
    rtl

; $04:B07B (was JSL $009779; X = the original cursor set for item $56)
TitleCursor4:
    phx
    jsr DetectMultitap
    plx
    bcs +
    jml Orig_DrawString
+   lda $56 : and #$0007 : asl : tax
    lda.l T4Cursors,x : tax
    phb : phk : plb
    jsl Orig_DrawString
    plb
    rtl

; $00:8580 (was JML $009779): the chosen item flashing after START ($00:8564 picks
; its string by $56; $F0 = blank this frame). X = the original string.
TitleFlash4:
    phx
    jsr DetectMultitap
    plx
    bcs +
    jml Orig_DrawString
+   lda $56 : and #$0007 : asl : tax
    lda.l T4Items,x : tax
    phb : phk : plb
    jsl Orig_DrawString
    plb
    rtl

T4Cursors:  dw T4Cursor0, T4Cursor1, T4Cursor2, T4Cursor3, T4Cursor4
T4Items:    dw T4OnePlayer, T4Players, T4Option, T4TimeTrial, T4Versus

T4OnePlayer:    dw $5266 : db $02, $00, $1F, $1B, $10, $28, $14, $21, $FF                 ; 1 PLAYER
T4Players:      dw $52A6 : db $03, $2B, $05, $00, $1F, $1B, $10, $28, $14, $21, $22, $FF  ; 2-4 PLAYERS
T4Versus:       dw $52B3 : db $25, $14, $21, $22, $24, $22, $FF                           ; VERSUS
T4TimeTrial:    dw $5273 : db $23, $18, $1C, $14, $00, $23, $21, $18, $10, $1B, $FF       ; TIME TRIAL
T4Option:       dw $52E6 : db $1E, $1F, $23, $18, $1E, $1D, $FF                           ; OPTION

; cursor at one place, blanks at the others (places: 1P, 2-4P, OPTION, TIME TRIAL, VERSUS)
macro t4cursor(a, b, c, d, e)
    dw $5265 : db <a>, $FE
    dw $52A5 : db <b>, $FE
    dw $52E5 : db <c>, $FE
    dw $5272 : db <d>, $FE
    dw $52B2 : db <e>, $FF
endmacro
T4Cursor0:  %t4cursor($F6, $00, $00, $00, $00)
T4Cursor1:  %t4cursor($00, $F6, $00, $00, $00)
T4Cursor2:  %t4cursor($00, $00, $F6, $00, $00)
T4Cursor3:  %t4cursor($00, $00, $00, $F6, $00)
T4Cursor4:  %t4cursor($00, $00, $00, $00, $F6)

Title4End:
assert Title4End <= $20FFFF, "title4 code overflows bank $20"

; ---- hooks ----
org $04B0CE : jsl TitleText4 : rts
org $04B07B : jsl TitleCursor4
org $008580 : jml TitleFlash4
