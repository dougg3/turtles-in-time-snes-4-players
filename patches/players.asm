; Player-ownership lookups for up to four players.
;
; The original code decides "P1 or P2" with `CPX #$0400` and picks P1's or P2's
; data. These helpers return the data for the player owning an object and keep
; the original default (anything that is not P1 is treated as P2), so 1P/2P
; behavior is unchanged. P3/P4 cases only match the new slots, which are never
; used in a 1P/2P game. Every helper also reproduces the CPU flags the original
; sequence left behind (see each one).

; ---- P3/P4 assignments ----
!P1_slot   = $0400
!P2_slot   = $0470
!P3_slot   = $0630      ; slot 5
!P4_slot   = $0710      ; slot 7
!P1_compB  = $05C0
!P2_compB  = $06A0
!P3_compB  = $1040      ; slot 28 (freed by the 3P/4P enemy cap)
!P4_compB  = $1430      ; slot 37
!P1_info   = $1A80
!P2_info   = $1AC0
!P3_info   = $1B20
!P4_info   = $1B60

org $00FA00
assert JoypadEnd <= $00FA00, "input code runs into the player helpers"

; Y = info block of the player owning object X (default P2).
; Replaces: LDY #$1A80 / CPX #$0400 / BEQ / LDY #$1AC0
; Flags as the original: P1 Z=1 C=1 N=0; others Z=0 C=1 N=0 (via CPY #$1A80).
InfoBlockForX:
    ldy #!P1_info : cpx #!P1_slot : beq .done
    ldy #!P3_info : cpx #!P3_slot : beq .done
    ldy #!P4_info : cpx #!P4_slot : beq .done
    ldy #!P2_info
.done:
    cpy #!P1_info
    rtl

; A = info block of the player owning object X (default P2). Same flags (CMP).
; Replaces: LDA #$1A80 / CPX #$0400 / BEQ / LDA #$1AC0
InfoBlockForX_A:
    lda #!P1_info : cpx #!P1_slot : beq .done
    lda #!P3_info : cpx #!P3_slot : beq .done
    lda #!P4_info : cpx #!P4_slot : beq .done
    lda #!P2_info
.done:
    cmp #!P1_info
    rtl

; X = info block of the player owning object X (default P2); A preserved.
; Replaces: CPX #$0400 / BNE / LDX #$1A80 (+ the LDX #$1AC0 path) at $00:C8B2.
InfoBlockToX:
    cpx #!P1_slot : beq .p1
    cpx #!P3_slot : beq .p3
    cpx #!P4_slot : beq .p4
    ldx #!P2_info : rtl
.p1: ldx #!P1_info : rtl
.p3: ldx #!P3_info : rtl
.p4: ldx #!P4_info : rtl

; Y = info block, A = player index x2, for object X (default P2).
; Replaces at $00:ADBF: LDY #$1A80 / LDA #$0000 / CPX #$0400 / BEQ / LDY #$1AC0 / LDA #$0002
InfoAndIndexForX:
    cpx #!P1_slot : beq .p1
    cpx #!P3_slot : beq .p3
    cpx #!P4_slot : beq .p4
    ldy #!P2_info : lda #$0002 : rtl
.p1: ldy #!P1_info : lda #$0000 : rtl
.p3: ldy #!P3_info : lda #$0004 : rtl
.p4: ldy #!P4_info : lda #$0006 : rtl

; A = info block for object Y if it is a player's main or companion-B slot,
; carry clear; carry set otherwise ($04:822B also maps the companion-B slots).
InfoBlockForY_Strict:
    lda #!P1_info : cpy #!P1_compB : beq .yes : cpy #!P1_slot : beq .yes
    lda #!P2_info : cpy #!P2_compB : beq .yes : cpy #!P2_slot : beq .yes
    lda #!P3_info : cpy #!P3_compB : beq .yes : cpy #!P3_slot : beq .yes
    lda #!P4_info : cpy #!P4_compB : beq .yes : cpy #!P4_slot : beq .yes
    sec
    rtl
.yes:
    clc
    rtl
; ---- player index x2 (0/2/4/6) from an object pointer; default (not P1/P3/P4) = 2 ----
; Used where the original did `CPx #$0400 ; BEQ ; ... 2` (patterns B and C).
IndexYfromX:
    ldy #$0000 : cpx #!P1_slot : beq .done
    ldy #$0004 : cpx #!P3_slot : beq .done
    ldy #$0006 : cpx #!P4_slot : beq .done
    ldy #$0002
.done: rtl
IndexYfromA:
    ldy #$0000 : cmp #!P1_slot : beq .done
    ldy #$0004 : cmp #!P3_slot : beq .done
    ldy #$0006 : cmp #!P4_slot : beq .done
    ldy #$0002
.done: rtl
IndexAfromX:
    lda #$0000 : cpx #!P1_slot : beq .done
    lda #$0004 : cpx #!P3_slot : beq .done
    lda #$0006 : cpx #!P4_slot : beq .done
    lda #$0002
.done: rtl
IndexAfromY:
    lda #$0000 : cpy #!P1_slot : beq .done
    lda #$0004 : cpy #!P3_slot : beq .done
    lda #$0006 : cpy #!P4_slot : beq .done
    lda #$0002
.done: rtl
PlayerHelpersEnd:
assert PlayerHelpersEnd <= $00FFB0, "player helpers overflow bank $00 padding"

; ---- pattern A sites (info block chosen by slot) ----
; Each original sequence is replaced by JSL + BRA to where the sequence ended.
; NOTE: Asar treats `bra $ADD0` (a number) as a raw operand byte, so branch targets inside
; original code must be labels (assigned below).
Orig_ADD0 = $00ADD0
Orig_AE4D = $00AE4D
Orig_C8BA = $00C8BA
Orig_CF09 = $00CF09
Orig_EF18 = $00EF18
Orig_8248 = $048248
Orig_AE73 = $04AE73
Orig_F3A0 = $04F3A0

org $00ADBF                 ; LDY #$1A80 ... LDA #$0002 (17 bytes) -> STA $1864 at $ADD0
    jsl InfoAndIndexForX
    bra Orig_ADD0
org $00AE42                 ; -> LDA $06,X at $AE4D
    jsl InfoBlockForX
    bra Orig_AE4D
org $00AF7A                 ; subroutine: LDY ... RTS
    jsl InfoBlockForX
    rts
org $00C8B2                 ; CPX/BNE/LDX #$1A80 (+ $C8C9 LDX #$1AC0) -> STA $0022,X at $C8BA
    jsl InfoBlockToX
    bra Orig_C8BA
org $00CEFE                 ; -> TAX at $CF09
    jsl InfoBlockForX_A
    bra Orig_CF09
org $00EF0D                 ; -> STA $04 at $EF18
    jsl InfoBlockForX_A
    bra Orig_EF18
org $04822B                 ; companion-aware mapper (after PHA at $822A)
    jsl InfoBlockForY_Strict
    bcc Orig_8248               ; found: TAY / PLA ... as before
    pla
    sec
    rts
org $04AE68                 ; -> TYX at $AE73
    jsl InfoBlockForX
    bra Orig_AE73
org $04F395                 ; -> LDA #$0001 at $F3A0
    jsl InfoBlockForX
    bra Orig_F3A0

; ---- patterns B/C: player index x2 chosen by slot ----
Orig_C288 = $03C288
Orig_CC18 = $03CC18
Orig_DF01 = $03DF01
Orig_82A2 = $0482A2
Orig_960E = $04960E
Orig_AD5B = $04AD5B
Orig_DEF7 = $00DEF7
Orig_C5B9 = $03C5B9
Orig_FA62 = $03FA62
Orig_8454 = $048454

org $03C27C                 ; LDY #0 / LDA $FE / CMP #$0400 / BEQ / INY / INY -> LDA $19DC,Y
    lda $FE
    jsl IndexYfromA
    bra Orig_C288
org $03CC0C                 ; same shape -> LDA $19DC,Y
    lda $FE
    jsl IndexYfromA
    bra Orig_CC18
org $03DEF9                 ; TDC / CPY #$0400 / BEQ / INC A / INC A -> TAY
    jsl IndexAfromY
    bra Orig_DF01
org $048298                 ; LDY #0 / CPX #$0400 / BEQ / INY / INY -> LDA $19DC,Y
    jsl IndexYfromX
    bra Orig_82A2
org $049603                 ; char select confirm: LDY #0 / CPX / BEQ / LDY #2 -> LDA $0028,Y
    jsl IndexYfromX
    bra Orig_960E
org $04AD50                 ; LDY #0 / CPX / BEQ / LDY #2 -> CLC / ADC $DA50,Y  (4-entry table: PlayerDA50)
    jsl IndexYfromX
    bra Orig_AD5B
org $00DEEB                 ; spawn X offset: LDA #0 / CPX / BEQ / CLC / ADC #2 -> TAY ($9F19,Y, 4-entry table: PlayerSpawnOffsetX)
    jsl IndexAfromX
    bra Orig_DEF7
org $03C5B1                 ; TDC / CPY / BEQ / INC / INC -> STA $32,X (enemy's target index)
    jsl IndexAfromY
    bra Orig_C5B9
org $03FA5A                 ; same -> STA $32,X
    jsl IndexAfromY
    bra Orig_FA62
org $04844C                 ; TDC / CPX / BEQ / INC / INC -> STA $00
    jsl IndexAfromX
    bra Orig_8454
