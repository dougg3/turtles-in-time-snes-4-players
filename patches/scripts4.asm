; Scene-transition scripts that only knew P1 and P2.
;
; Bank $04 scripts (step counter $1782) reset, place and pose the players through
; $9E/$A0 only. In 3P/4P, P3/P4 kept whatever they were doing (before the Shredder
; tank, mode $0C script $04:F101, they stayed where the corridor ended).
; P3 does what P1 does, P4 what P2 does (same routines, $1864 = 4/6). 1P/2P: the
; original code.
;   $04:F36D  reset (state/sub)             callers $04:F362, $04:F411
;   $04:F385  reset + info +6 = 1           tank intro $04:F111, $04:F37E
;   $04:F124  place (x $01:E99A, y $C0)     tank intro
;   $04:F22B  pose (animations $01:EBB0)    tank intro $04:F1D1
;   $04:F27F  pose step (every frame)       $04:F0EF (tank intro), $04:AFA8
;   $04:F250  pose (animations $01:EBBA)    $04:AFC4
;   $04:F022  time-warp arrival (scenes 5-9): animates slots 4-6 ($05C0, $0630,
;             $06A0) every frame, $04:F013 clears $05C0/$06A0 at the end. In 3P/4P
;             slot 5 is P3's turtle and P3's/P4's portal objects are $1530/$1640.
;   After Super Shredder (script $04:AFBA, started at $02:84DF): $04:ACEA counts
;             P1/P2 and waits for $A8+1 of them, $04:AD0A walks them to the clear
;             line-up (state $36; spots by side, $04:AD50), $04:AD83 waits for
;             state $37. 3P/4P: all present players; P3 on P1's side, P4 on P2's;
;             "all done" = at least the count taken at the start (no hang when
;             a player drops out).
;   Lives tally (script at $04:AE1F): $04:AE45 counts each player's lives into
;             the score ($04:AE64, info via $00:FA00) and waits for $A8+1
;             players, $04:AEBD cheers (state $29): also P3/P4.
;   $00:D4F2 / $00:D546  frozen (state $16): start = ice palette (script $8D6B
;             P1 / $8D6F P2: record $93EF/$93F2, $09:9379), end = the turtle's
;             palette again; both on P1's/P2's palette (P3/P4 got P1's/P2's
;             script in an effect block nobody runs, or made P2 flash). P3/P4: a
;             freeze flag; extensions4 builds palette 8/9 from the ice palette while
;             it is set.
;   $03:8BA9  scene-start clears: per-player word array and hit flags only for
;             P1/P2 (STZ $1A50/$1A52, $1A58/$1A5A): all four.
;   $03:C816  enemy held for the slam: frames from $01:B8AD, P1's list if the
;             holder index +$32 = 0, else P2's: P3 (4) got P2's frames, whose tiles
;             are in P2's upload area. P3 -> P1's list (P3's tiles are numbered as
;             P1's, on its own extension page), P4 -> P2's.
;   $03:C8B0, $03:C935  lift/throw frames: index (pose * 4) | holder index ($01:B8BD,
;             $01:B8CD: [P1 frame, P2 frame] per pose): P3 (4) / P4 (6) read the next
;             pose's entries. Now (pose * 4) | (index & 2): P3 as P1, P4 as P2.
;   $00:ADA6  players carried along with object $187E (Rat King fight; called
;             from $00:A758): only $9E/$A0 -> P3/P4 drifted off the right edge
;             (Scene 3: P1/P2 x <= 207, P3/P4 up to 244). $00:ADB7 is 4-way already.
;   $04:AC28  time-warp departure (end of scenes 5-9; "CLEAR!"): each player
;             hidden (+$00 = 0, $04:AC73), companion A cleared, companion B = warp
;             effect (type 3, $04:AC5A; data $E7EA P1 / $E7FC P2); then $04:AC91
;             animates slots 4-6 ($04:F022: slot 5 = P3's turtle: drawn as junk)
;             and $04:AC9A clears via $04:F013. P3/P4: same start (P3 with P1's
;             data, P4 with P2's); the animation goes to ScrPortalAnim4.
;   Camera ($04:EA12, players4 CamCalc): with P1 and P2 present the two-player
;             camera (leader/trailer CamA/CamB), with one of them the one-player
;             camera on it, with neither X = 0 (reads $0008: the camera jerks). In
;             3P/4P CamA/CamB also counted absent P1/P2 (stale X). Now 3P/4P: by
;             the number of present players (any of the four), and CamA/CamB =
;             max/min X over present players only.
;   $00:C771  flag +$30 bit 6 off, companion A effect ($00:B96E); caller $04:8E76,
;             0x30 frames into the last section (only section 32 sets $1630)

!ScrSave1864 = $1D42                ; free RAM after tally4's scratch ($1D30-$1D41)
!ScrClrTotal = $1D44                ; players in the clear line-up (3P/4P)

org $20D800
assert Tally4End <= $20D800, "tally4 code runs into scripts4"

; carry set if 3P/4P
Scr4Mode:
    lda !PlayerMode : and #$00FF : cmp #$0003
    rtl

; ---- $04:F36D (was LDX $9E / BEQ / STZ $16,X / STZ $38,X / LDX $A0 ...) ----
ScrReset4:
    ldx $9E : beq +
    stz $16,x : stz $38,x
+   ldx $A0 : beq +
    stz $16,x : stz $38,x
+   jsl Scr4Mode : bcc .done
    ldx !P3_ptr : beq +
    stz $16,x : stz $38,x
+   ldx !P4_ptr : beq .done
    stz $16,x : stz $38,x
.done:
    rtl

; ---- $04:F385 (was LDX $9E / BEQ / JSL $04F391 / LDX $A0 / BEQ / [F391]) ----
; $04:F391 picks the info block with CPX #$0400 (P1, else P2): P3/P4 done here.
ScrResetInfo4:
    ldx $9E : beq +
    jsl $04F391
+   ldx $A0 : beq +
    jsl $04F391
+   jsl Scr4Mode : bcc .done
    lda #$0001
    ldx !P3_ptr : beq +
    stz $16,x : stz $38,x
    sta.w !P3_info+6
+   ldx !P4_ptr : beq .done
    stz $16,x : stz $38,x
    sta.w !P4_info+6
.done:
    rtl

; ---- $04:F13A (P2's half of the placement; was LDX $A0 / BEQ $F165) ----
; Y = P2's index into $01:E99A/E9A0. P3 left of the tank behind P1, P4 right
; behind P2, facing like P1/P2.
ScrPlace4:
    ldx $A0 : beq +
    lda #$0002
    jsl $04F141
+   jsl Scr4Mode : bcc .done
    lda $1864 : sta.l !ScrSave1864
    ldx !P3_ptr : beq +
    lda #$0004 : sta $1864
    lda $04,x : and #$2020 : sta $04,x
    lda #$0030
    jsr .xy
+   ldx !P4_ptr : beq +
    lda #$0006 : sta $1864
    lda $04,x : and #$2020 : ora #$2020 : sta $04,x
    lda #$00D0
    jsr .xy
+   lda.l !ScrSave1864 : sta $1864
.done:
    rtl
; as $04:F14E-F164: A = x
.xy:
    sta $08,x
    lda #$00A0 : sta $0C,x
    stz $10,x
    ldy $14,x
    lda $EBA6,y                     ; DB = $01, as the original
    jsl $04936E
    rts

; ---- $04:F1D1 (was JSL $04F22B) ----
ScrPose4:
    jsl $04F22B
    jsl Scr4Mode : bcc .done
    lda $1864 : sta.l !ScrSave1864
    ldx !P3_ptr : beq +
    lda #$0004
    jsl $04F20E                     ; as P1: $42 = 0, delay 8
+   ldx !P4_ptr : beq +
    lda #$0006 : sta $1864          ; as P2 ($04:F23E): $42 = 7, delay $C
    lda #$003C : sta $5E,x
    lda #$0007 : sta $42,x
    ldy #$000C
    jsl $04F21B
+   lda.l !ScrSave1864 : sta $1864
.done:
    rtl

; ---- $04:F0EF, $04:AFA8 (was JSL $04F27F) ----
ScrPoseStep4:
    jsl $04F27F
    jsl Scr4Mode : bcc .done
    lda $1864 : sta.l !ScrSave1864
    ldx !P3_ptr : beq +
    lda #$0004
    jsl $04F291
+   ldx !P4_ptr : beq +
    lda #$0006
    jsl $04F291
+   lda.l !ScrSave1864 : sta $1864
.done:
    rtl

; ---- $04:AFC4 (was JSL $04F250) ----
ScrPoseB4:
    jsl $04F250
    jsl Scr4Mode : bcc .done
    lda $1864 : sta.l !ScrSave1864
    ldx !P3_ptr : beq +
    lda #$0004 : ldy #$000C         ; as P1
    jsl $04F268
+   ldx !P4_ptr : beq +
    lda #$0006 : ldy #$0011         ; as P2
    jsl $04F268
+   lda.l !ScrSave1864 : sta $1864
.done:
    rtl

;---- $00:C77F (P2's half; was LDX $A0 / BEQ $C79A) ----
; $00:B96E picks P1's effect (tiles $8000) for companion $04E0, else P2's; P3's
; companion uses P1's, P4's P2's (as their other companion graphics).
ScrCompEffect4:
    ldx $A0 : beq +
    jsl $00C783
+   jsl Scr4Mode : bcc .done
    ldx !P3_ptr : beq +
    lda $30,x : and #$FFBF : sta $30,x
    ldx.w #!P3_compA
    ldy #$E898 : lda #$8000
    jsr .effect
+   ldx !P4_ptr : beq .done
    lda $30,x : and #$FFBF : sta $30,x
    ldx.w #!P4_compA
    ldy #$E89C : lda #$8200
    jsr .effect
.done:
    rtl
; as $00:B97F-B98D
.effect:
    sta $02,x
    lda #$0001
    jsl $04D26A
    lda #$0002 : sta $5E,x
    rts

;---- $04:F003 (was JSL $04F022): animate the arrival objects ----
ScrPortalAnim4:
    jsl Scr4Mode : bcs +
    jml $04F022                     ; original (RTL returns to our caller)
+   ldx #$05C0 : jsr .one
    ldx #$06A0 : jsr .one
    ldx.w #!P3_compB : jsr .one
    ldx.w #!P4_compB : jsr .one
    rtl
.one:
    lda $14,x : beq +
    jsl $04D2A7
+   rts

;---- $04:F013 (was LDX #$05C0 / JSL $008BCD / LDX #$06A0 / JSL $008BCD) ----
ScrPortalClear4:
    ldx #$05C0 : jsl $008BCD
    ldx #$06A0 : jsl $008BCD
    jsl Scr4Mode : bcc .done
    ldx.w #!P3_compB : jsl $008BCD
    ldx.w #!P4_compB : jsl $008BCD
.done:
    rtl

;---- players present: A = count of P1..P4 with an object (+$14 set) ----
ScrCountPresent:
    phx
    stz $02
    lda $0414 : beq + : inc $02
+   lda $0484 : beq + : inc $02
+   ldx !P3_ptr : beq + : lda $14,x : beq + : inc $02
+   ldx !P4_ptr : beq + : lda $14,x : beq + : inc $02
+   lda $02
    plx
    rts

;---- $04:ACEA (clear line-up: count; was STZ $178A / ...) ----
ScrClrCount4:
    jsl Scr4Mode : bcs .four
    stz $178A                       ; original
    lda $0414 : beq + : inc $178A
+   lda $0484 : beq + : inc $178A
+   lda $A8 : inc : cmp $178A : bne +
    inc $1782
+   rtl
.four:
    jsr ScrCountPresent : beq .wait
    sta.l !ScrClrTotal
    cmp #$0003 : bcc +
    lda #$0002                      ; spot tables ($01:DA54) cover 1-2 players
+   sta $178A
    inc $1782
.wait:
    rtl

;---- $04:AD0A (walk to the line-up; was STZ $00 / LDX #$0400 ...) ----
ScrClrWalk4:
    stz $00
    ldx #$0400 : jsl $04AD21
    ldx #$0470 : jsl $04AD21
    jsl Scr4Mode : bcs +
    jml $04ADA5                     ; original: $00 == $178A -> next step
+   ldx !P3_ptr : beq +
    jsl $04AD21
    lda #$FFE8 : jsr .offset        ; P3: left of P1's spot, nearer the front
+   ldx !P4_ptr : beq +
    jsl $04AD21
    lda #$0018 : jsr .offset        ; P4: right of P2's spot
+   brl ScrClrDone
; target x (+$42) += A, target y (+$5E) += $10, once: only just after $04:AD21 set
; state $36 (sub-state 0). Kept on screen ($18-$E8) when the spot is a screen
; position; Scene 8's spots are relative to its scrolling (P1 -$20, P2 +$20: no clamp)
; No offset when P1 and P2 walk to the same spot (into a door: Scene 4 before
; Shredder; P3/P4 stopped short outside it, user report).
.offset:
    pha
    lda $16,x : cmp #$0036 : bne .skip
    lda $38,x : bne .skip
    jsr .sameSpot : beq .skip
    lda $42,x : cmp #$0100 : bcc +
    pla : clc : adc $42,x : bra ++
+   pla : clc : adc $42,x
    cmp #$0018 : bcs + : lda #$0018
+   cmp #$00E8 : bcc ++ : lda #$00E8
++  sta $42,x
    lda $5E,x : clc : adc #$0010 : sta $5E,x
    rts
.skip:
    pla
    rts
; Z set if P1's and P2's spots in this step are the same ($04:AD3C, tables in bank $01: index =
; $DA3E[$1784] + $DA54[$178A - 1] + $DA50[player: P1 0, others 2]; x $D9AE, y $D9F6).
; From the tables, as P1/P2 may get theirs later. Keeps X.
.sameSpot:
    phx
    ldy #$0000
    lda.l $001784 : asl : tax
    lda.l $01DA3E,x : pha
    lda.l $00178A : dec : asl : tax
    lda.l $01DA54,x : clc : adc 1,s : sta 1,s   ; 1,s: base
    clc : adc.l $01DA50 : tax
    lda.l $01D9AE,x : pha                       ; P1's x
    lda.l $01D9F6,x : pha                       ; P1's y (1,s y, 3,s x, 5,s base)
    lda 5,s : clc : adc.l $01DA52 : tax
    lda.l $01D9F6,x : cmp 1,s : bne +
    lda.l $01D9AE,x : cmp 3,s : bne +
    iny
+   pla : pla : pla
    plx
    cpy #$0001
    rts

;---- $04:AD83 (wait until arrived, state $37; was STZ $00 / LDX #$0400 ...) ----
ScrClrArrive4:
    stz $00
    ldx #$0400 : jsr .one
    ldx #$0470 : jsr .one
    jsl Scr4Mode : bcs +
    jml $04ADA5
+   ldx !P3_ptr : beq + : jsr .one
+   ldx !P4_ptr : beq + : jsr .one
+   bra ScrClrDone
.one:
    lda $14,x : beq +
    lda $16,x : cmp #$0037 : bne +
    inc $00
+   rts

ScrClrDone:                         ; 3P/4P: next step once $00 >= players counted
    lda $00 : cmp.l !ScrClrTotal : bcc +
    jml $04ADC4                     ; INC $1782 / RTL
+   rtl

;---- $04:AE45 (lives tally; was LDX #$0400 / JSL $04AE64 / LDX #$0470 / ...) ----
ScrLives4:
    ldx #$0400 : jsl $04AE64
    ldx #$0470 : jsl $04AE64
    jsl Scr4Mode : bcs .four
    jml $04AE53                     ; original: JSL $04AE36 / $A8+1 == $1796 ?
.four:
    ldx !P3_ptr : beq + : jsl $04AE64
+   ldx !P4_ptr : beq + : jsl $04AE64
+   jsl $04AE36
    jsr ScrCountPresent
    cmp $1796 : beq + : bcc +
    rtl
+   jml $04AE9F                     ; INC $1782 / RTL

;---- $04:AED3 (cheer, after P1/P2; was LDA #$00F4 / JML $04AEB1) ----
ScrCheer4:
    jsl Scr4Mode : bcc +
    ldx !P3_ptr : beq ++ : lda $14,x : beq ++ : jsl $04AEDA
++  ldx !P4_ptr : beq + : lda $14,x : beq + : jsl $04AEDA
+   lda #$00F4
    jml $04AEB1

;---- $00:D546 (freeze end; was LDY $1864 / BNE $D556) ----
ScrPalEffect4:
    ldy $1864 : bne +
    jml $00D54B                     ; P1
+   cpy #$0004 : bcs +
    jml $00D556                     ; P2
+   lda #$0000                      ; P3/P4: freeze flag off
    sta.w !PPIceP3-4,y
    jml $00D553                     ; LDX $FC / RTL

;---- $00:D4F2 (freeze start; was LDY $1864 / LDX $FE40,Y / LDA $FE48,Y / TAY /
; JSL $00A155) ----
ScrFreeze4:
    ldy $1864 : cpy #$0004 : bcs +
    ldx $FE40,y                     ; P1/P2: original (DB = $01)
    lda $FE48,y
    tay
    jsl $00A155
    jml $00D500
+   lda #$0001                      ; P3/P4: freeze flag on
    sta.w !PPIceP3-4,y
    jml $00D500

;---- $03:8BA9 (was STZ $1A50 / STZ $1A52; $1A58/$1A5A follow): all four players ----
ScrClearPlayerWords4:
    lda #$0000
    sta.l !PlayerWordArray : sta.l !PlayerWordArray+2
    sta.l !PlayerWordArray+4 : sta.l !PlayerWordArray+6
    sta.l !PlayerHitFlags+4 : sta.l !PlayerHitFlags+6
    rtl

;---- $03:C816 (was LDA $32,X / BEQ / INY / INY) ----
ScrHeldFrames4:
    lda $32,x : and #$0002 : beq +  ; P2/P4 side
    iny : iny
+   rtl

;---- $03:C8B0 / $03:C935 (was ASL / ASL / ORA $32,X / TAY) ----
ScrThrowFrames4:
    asl : asl
    pha
    lda $32,x : and #$0002
    ora $01,s
    tay
    pla
    rtl

;---- $00:ADB3 (P2's half; was LDX $A0 / BEQ $ADA5) ----
ScrCarry4:
    ldx $A0 : beq +
    jsl $00ADB7
+   jsl Scr4Mode : bcc .done
    ldx !P3_ptr : beq +
    jsl $00ADB7
+   ldx !P4_ptr : beq .done
    jsl $00ADB7
.done:
    rtl

;---- $04:AC28 (was LDA #$0030 / STA $178A; P1/P2 follow) ----
ScrWarpOut4:
    lda #$0030 : sta $178A
    jsl Scr4Mode : bcc .done
    ldx !P3_ptr : beq +
    lda.w #!P3_compA : sta.l !ScrSave1864
    ldy #$E7EA : lda.w #!P3_compB
    jsr .one
+   ldx !P4_ptr : beq .done
    lda.w #!P4_compA : sta.l !ScrSave1864
    ldy #$E7FC : lda.w #!P4_compB
    jsr .one
.done:
    rtl
; X = player, Y = effect data, A = companion B, !ScrSave1864 = companion A
; (as $04:AC73 + $04:AC35-AC42)
.one:
    pha : phy
    stz $00,x                       ; player hidden
    lda $10,x : sec : sbc #$005C : sta $00
    lda $08,x : sta $02
    lda $0C,x : sta $04
    lda.l !ScrSave1864 : tax
    jsl $008BCD                     ; companion A cleared
    ply : plx
    jsl $04AC5A                     ; companion B: warp effect at the player
    rts

;---- $04:EA12 (was LDX $9E / BEQ $EA21 / LDX $A0 / BNE $EA49; then $EA1C) ----
CamSelect4:
    jsl Scr4Mode : bcs .four
    ldx $9E : bne +                 ; original
    jml $04EA21
+   ldx $A0 : beq +
    jml $04EA49
+   jml $04EA1C
.four:
    stz $02                         ; count of present players
    ldx $9E : jsr .one
    ldx $A0 : jsr .one
    ldx !P3_ptr : jsr .one
    ldx !P4_ptr : jsr .one
    lda $02 : beq +
    cmp #$0002 : bcs ++
    ldx $00                         ; exactly one: one-player camera on it
    jml $04EA24
+   jml $04EA21                     ; nobody: as the original
++  jml $04EA49                     ; two or more: leader/trailer camera
.one:
    cpx #$0000 : beq +
    stx $00
    inc $02
+   rts

;---- CamA/CamB (players4 CamCalc, JSRed by the camera blocks; returns to them) ----
CamCalcFar:
    lda $0408 : sta !CamA           ; 1P/2P: P1 X / P2 X (the original reads)
    lda $0478 : sta !CamB
    jsl Scr4Mode : bcc .done
    lda #$0000 : sta !CamA          ; 3P/4P: max / min X over present players
    lda #$FFFF : sta !CamB
    ldy $9E : jsr .take
    ldy $A0 : jsr .take
    ldy !P3_ptr : jsr .take
    ldy !P4_ptr : jsr .take
    lda !CamB : cmp #$FFFF : bne .done
    lda $0408 : sta !CamA           ; nobody present: as 1P/2P
    lda $0478 : sta !CamB
.done:
    rtl
.take:                              ; Y = player object or 0 (absent)
    cpy #$0000 : beq +
    lda $0008,y
    cmp !CamA : bcc ++
    sta !CamA
++  cmp !CamB : bcs +
    sta !CamB
+   rts

;---- $00:AA00 (game-over screen start, mode $0D; was JSL $00AA07 with X = P1's info):
; $00:AA07 = HUD clear $04:D89B, info state 5 ($04:D4F4: GAME OVER next), $04:D751.
; The original does it for P1/P2 only; a P3/P4 still in the game stayed in its
; continue state and showed WAIT ----
GameOverInfo4:
    jsl $00AA07                     ; P1 (original)
    php
    rep #$30
    jsl Scr4Mode : bcc .done
    ldx.w #!P3_info : lda $0000,x : beq +
    jsl $00AA07
+   ldx.w #!P4_info : lda $0000,x : beq .done
    jsl $00AA07
.done:
    plp
    rtl

;---- $02:9E0B (final screen "THANK YOU FOR YOUR PLAYING!", after the 1P/2P points on
; row 21, before the game time on row 23; was LDY #$52F1 / JSL $008D3E): "3P-POINTS"
; and "4P-POINTS" on the free row 22, laid out as row 21 ----
FinalPoints4:
    lda.l !EndPlayers : and #$0004 : beq +
    ldy #$52C1 : ldx #$0000 : jsr .label
    lda.l !P3_info+$1C : ldy #$52CB : jsr .score
+   lda.l !EndPlayers : and #$0008 : beq .done
    ldy #$52D1 : ldx #$0009 : jsr .label
    lda.l !P4_info+$1C : ldy #$52DB : jsr .score
.done:
    ldy #$52F1 : jsl $008D3E        ; original
    jml $029E12
.label:                             ; Y = BG3 map address, X = offset in .labels
    phx
    jsl $008D3E
    plx
    lda #$0009 : sta.l !FinTmp
-   lda.l .labels,x : and #$00FF : ora #$3900
    phx
    jsl $008D74
    plx
    inx
    lda.l !FinTmp : dec : sta.l !FinTmp : bne -
    jsl $008D7F
    rts
.score:                             ; A = points (4 BCD digits), Y = map address
    sta $00                         ; (as $02:9E57)
    jsl $008D3E
    lda #$0004 : sta.l !FinTmp
-   lda #$0000
    asl $00 : rol : asl $00 : rol : asl $00 : rol : asl $00 : rol
    clc : adc #$0001 : ora #$3900
    jsl $008D74
    lda.l !FinTmp : dec : sta.l !FinTmp : bne -
    jsl $008D7F
    rts
.labels:                            ; "3P-POINTS", "4P-POINTS" (digit = value + 1,
    db $04, $1F, $2B, $1F, $1E, $18, $1D, $23, $22  ; A = $10, - = $2B)
    db $05, $1F, $2B, $1F, $1E, $18, $1D, $23, $22

Scripts4End:
assert Scripts4End <= $20FFFF, "scripts4 code overflows bank $20"

; ---- hooks ----
org $04F36D : jml ScrReset4         ; whole routine (ends RTL at $F37D)
org $04F385 : jml ScrResetInfo4     ; LDX $9E / BEQ (F389-F3A6 stay: $04:F391 entry)
org $04F13A : jml ScrPlace4         ; LDX $A0 / BEQ (F13E-F165 stay: $04:F141 entry)
org $04F1D1 : jsl ScrPose4
org $04F0EF : jsl ScrPoseStep4
org $04AFA8 : jsl ScrPoseStep4
org $04AFC4 : jsl ScrPoseB4
org $04ACEA : jml ScrClrCount4
org $04AD0A : jml ScrClrWalk4
org $04AD83 : jml ScrClrArrive4
org $04AE45 : jml ScrLives4         ; (AE53 / AE9F stay: jump targets)
org $04AED3 : jml ScrCheer4
org $04F003 : jsl ScrPortalAnim4
org $04AC91 : jsl ScrPortalAnim4    ; departure, per frame (was JSL $04F022)
org $04AC28                         ; LDA #$0030 / STA $178A (6 bytes)
    jsl ScrWarpOut4
    nop #2
assert pc() == $04AC2E
org $04F013                         ; 14 bytes up to the RTL at $04:F021
    jml ScrPortalClear4
    nop #10
assert pc() == $04F021
org $029E0B                         ; LDY #$52F1 / JSL $008D3E (7 bytes)
    jml FinalPoints4
    nop #3
assert pc() == $029E12
org $00AA00 : jsl GameOverInfo4     ; was JSL $00AA07 (P1; P2 follows at $00:AA04)
org $00C77F : jml ScrCompEffect4
org $00D546 : jml ScrPalEffect4
org $04EA12                         ; LDX $9E / BEQ $EA21 (5 bytes)
    jml CamSelect4
    nop
assert pc() == $04EA17
org $00D4F2 : jml ScrFreeze4        ; (D500 stays: continues)
org $00ADB3 : jml ScrCarry4         ; (ADB7 stays: JSL entry for one player)
org $03C8B0                         ; ASL / ASL / ORA $32,X / TAY (5 bytes)
    jsl ScrThrowFrames4
    nop
assert pc() == $03C8B5
org $03C935
    jsl ScrThrowFrames4
    nop
assert pc() == $03C93A
org $03C816                         ; 6 bytes up to LDA $B8AD,Y at $03:C81C
    jsl ScrHeldFrames4
    nop #2
assert pc() == $03C81C
org $038BA9                         ; STZ $1A50 / STZ $1A52 (6 bytes)
    jsl ScrClearPlayerWords4
    nop #2
assert pc() == $038BAF     ; (D54B / D553 / D556 stay: jump targets)    ; LDX $A0 / BEQ (C783-C79A stay: $00:C783 entry)
