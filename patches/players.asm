; Player-ownership lookups for up to four players.
;
; The original code decides "P1 or P2" with `CPX #$0400` and picks P1's or P2's
; data. These helpers return the data for the player owning an object and keep
; the original default (anything that is not P1 is treated as P2), so 1P/2P
; behavior is unchanged. P3/P4 cases only match the new slots, which are never
; used in a 1P/2P game. Every helper also reproduces the CPU flags the original
; sequence left behind (see each one).

; Slot/info addresses: ram.asm.
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

; Sprite tile base / palette for a player object ($00:921A, 8-bit A, 16-bit X):
; original: $00 for P1, $30 for anything else (= tiles $030+ and palette 1).
; Proof of concept: P3 shares P1's VRAM region and palette, P4 shares P2's (the
; extension sprite memory gives them their own).
TileBaseForX:
    lda #$00 : cpx #!P1_slot : beq .done
    cpx #!P3_slot : beq .done
    lda #$30
.done:
    rtl

; "Is object X a player's main slot?" for the OAM builder ($00:92FB), called with
; JSR (same 3 bytes as the original CPX #$04E0, so the BCC after it is kept).
; Carry clear = player (original: X < $04E0, i.e. slots 0/1); P3/P4 slots added.
; P3/P4 objects (mains in slots 5/7, companion A below $0400, companion B outside
; the pool) go to IsPlayerSlotFar (extensions4.asm): player test for the mains, and the
; extension marking of their OAM entries.
IsPlayerSlotX:
    cpx #$04E0 : bcs .high
    cpx #$0400 : bcc .far           ; below $0400: P3/P4 companion A
    clc                             ; P1/P2 exactly as before
    rts
.high:
    cpx #!P3_slot : beq .far
    cpx #!P4_slot : beq .far
    cpx #!P3_compB : beq .far
    cpx #!P4_compB : beq .far
    sec
    rts
.far:
    jsl IsPlayerSlotFar
.done:
    rts

; ---- companion A (slots 2/3 for P1/P2; P3/P4 outside the pool, ram.asm) ----

; Y = owner of companion-A object X (default P2). Replaces at $00:B6D0:
; LDY #$0400 / CPX #$04E0 / BEQ / LDY #$0470
OwnerOfCompanionA:
    ldy #!P1_slot : cpx #$04E0 : beq .done
    ldy #!P3_slot : cpx #!P3_compA : beq .done
    ldy #!P4_slot : cpx #!P4_compA : beq .done
    ldy #!P2_slot
.done:
    rtl

; Z set if companion-A object X should use P1-side data (P1, and P3 which shares
; P1's palette/tiles in the proof of concept). Same 3 bytes as CPX #$04E0 (JSR),
; registers preserved, the BEQ after it is kept.
IsP1SideCompanionA:
    cpx #$04E0 : beq .done
    cpx #!P3_compA
.done:
    rts

; ---- companion B = the player's attack/hit object (slots 4/6; P3/P4: ram.asm) ----
; Z set if companion-B object X uses P1-side data (P1, and P3 in the proof of
; concept). Same 3 bytes as CPX #$05C0 (JSR); BEQ after it kept.
IsP1SideCompanionB:
    cpx #!P1_compB : beq .done
    cpx #!P3_compB
.done:
    rts

; $00:C625: keep X if it is any player's companion B, else X = P2's ($06A0).
; Replaces CPX #$05C0 / BEQ / LDX #$06A0.
KeepCompanionB:
    cpx #!P1_compB : beq .done
    cpx #!P3_compB : beq .done
    cpx #!P4_compB : beq .done
    ldx #!P2_compB
.done:
    rtl

; Y = player index x2 for companion-B object A; carry set if A is not one.
; Replaces at $04:858E: CMP #$05C0 / BEQ / CMP #$06A0 / BNE / INY / INY
IndexYfromCompanionB_A:
    ldy #$0000 : cmp #!P1_compB : beq .yes
    ldy #$0002 : cmp #!P2_compB : beq .yes
    ldy #$0004 : cmp #!P3_compB : beq .yes
    ldy #$0006 : cmp #!P4_compB : beq .yes
    ldy #$0000
    sec
    rtl
.yes:
    clc
    rtl

; X = stat block credited for a hit by companion-B object A ($03:B49A/B8D9).
; Original: $1911 if A == $05C0 else $191B. Proof of concept: P3 -> P1's, P4 -> P2's
; (P3/P4 get their own blocks with the HUD work).
StatBlockForCompanionB_A:
    ldx #$1911 : cmp #!P1_compB : beq .done
    cmp #!P3_compB : beq .done
    ldx #$191B
.done:
    rtl
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

; ---- OAM builder: per-player sprite tile base / palette ($00:921A) ----
Orig_9223 = $009223
org $00921A                 ; LDA #$00 / CPX #$0400 / BEQ / LDA #$30 -> STA $D6
    jsl TileBaseForX
    bra Orig_9223

; ---- OAM builder: draw P3/P4 with the player path ($00:92FB CPX #$04E0 / BCC) ----
org $0092FB
    jsr IsPlayerSlotX

; ---- companion A: owner and per-player data ($00:B6D0, B959, B974, C5E8, C64C) ----
Orig_B6DB = $00B6DB
org $00B6D0                 ; LDY #$0400 / CPX #$04E0 / BEQ / LDY #$0470 -> LDA $0030,Y
    jsl OwnerOfCompanionA
    bra Orig_B6DB
org $00B959 : jsr IsP1SideCompanionA       ; was CPX #$04E0 (draw data / attributes)
org $00B974 : jsr IsP1SideCompanionA       ; was CPX #$04E0
org $00C5E8 : jsr IsP1SideCompanionA       ; was CPX #$04E0
org $00C64C : jsr IsP1SideCompanionA       ; was CPX #$04E0

; ---- companion B (attack object): data side, slot keep, attacker index, hit credit ----
org $00C5BD : jsr IsP1SideCompanionB       ; was CPX #$05C0
org $00C610 : jsr IsP1SideCompanionB       ; was CPX #$05C0
org $00C676 : jsr IsP1SideCompanionB       ; was CPX #$05C0
Orig_C62D = $00C62D
org $00C625                                ; CPX #$05C0 / BEQ / LDX #$06A0 -> JML $008BCD
    jsl KeepCompanionB
    bra Orig_C62D
Orig_859A = $04859A
Orig_859F = $04859F
org $04858E                                ; CMP #$05C0 / BEQ / CMP #$06A0 / BNE / INY / INY
    jsl IndexYfromCompanionB_A
    bcs Orig_859F
    bra Orig_859A
Orig_B4A2 = $03B4A2
Orig_B8E1 = $03B8E1
org $03B497                                ; LDX #$1911 / CMP #$05C0 / BEQ / LDX #$191B -> INC $00,X
    jsl StatBlockForCompanionB_A
    bra Orig_B4A2
org $03B8D6                                ; same -> INC $02,X
    jsl StatBlockForCompanionB_A
    bra Orig_B8E1
