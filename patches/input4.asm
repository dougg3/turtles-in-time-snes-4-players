; Four-player joypad reading.
;
; Original $00:85E8 (called once per frame from NMI at $00:81CB, DB=$01, D=$0000):
; reads JOY1-4 into held $0020+X / new $0028+X, then overwrites slot 3 with the
; P1|P2 combination. Replacement layout (index = player*2, same as $1864):
;   held:  $0020 P1, $0022 P2, $0024 P3, $0026 P4
;   new:   $0028 P1, $002A P2, $002C P3, $002E P4
;   combined (OR of all players): held $00DC, new $00DE   (were $0026/$002E)
; $DC-$DF/$E2-$E3 are only touched by the $00:8855/$00:88AF clear loops.
;
; P3 = multitap pad 3, delivered by auto-read in JOY4 ($421E) with $4201.7=1
; (the game never writes $4201). P4 = multitap pad 4, read serially after
; selecting pads 4/5 with $4201.7=0 (SNESdev wiki "Multitap"). Without a
; multitap, JOY4 reads 0 and the detection below fails, so P3=P4=0 and the
; combined words equal P1|P2 exactly as before.

!Combined_held = $DC
!Combined_new  = $DE
!Pad4_temp     = $E2

org $0085E8
    jml Joypad4

org $00F860
; Unrolled and call-free so the common case (no multitap) costs about the same
; CPU time as the original loop: several stages already lag in 2P, so
; extra cycles here would change which frames lag (seen: +880 master clocks
; per frame gave one extra lag frame in Scene 3 with a JSR-based version).
Joypad4:
    rep #$10
    sep #$20
.wait:
    lda $4212               ; wait for auto-joypad read to finish
    lsr
    bcs .wait
    rep #$20
    ; new = raw AND NOT previous held; held = raw   (same as the original loop)
    lda $20 : eor #$FFFF : and $4218 : sta $28 : lda $4218 : sta $20   ; P1 = JOY1
    lda $22 : eor #$FFFF : and $421A : sta $2A : lda $421A : sta $22   ; P2 = JOY2 (multitap pad 2)
    lda $24 : eor #$FFFF : and $421E : sta $2C : lda $421E : sta $24   ; P3 = JOY4 (multitap pad 3)
    ; P4 = multitap pad 4, read serially. Detection (SNESdev wiki): with strobe
    ; high a multitap reads 1 on $4017 D1 (an ordinary pad or nothing reads 0).
    sep #$20
    lda #$01 : sta $4016
    lda $4017
    and #$02
    beq .no_multitap
    ; second check: after strobe low, D1 must not read eight 1s
    stz $4016
    ldx #$0008
    ldy #$0000
.detect_low:
    lda $4017 : and #$02 : beq +
    iny
+   dex : bne .detect_low
    cpy #$0008 : beq .no_multitap_strobed
    lda #$7F : sta $4201            ; select multitap pads 4/5
    lda #$01 : sta $4016            ; re-latch all pads
    stz $4016
    rep #$20
    stz !Pad4_temp
    ldx #$0010
.bits:
    sep #$20
    lda $4017                       ; D0 = pad 4, MSB (B) first
    lsr                             ; bit 0 -> carry
    rep #$20
    rol !Pad4_temp
    dex : bne .bits
    sep #$20
    lda #$FF : sta $4201            ; back to pads 2/3 for the next auto-read
    rep #$20
    lda $26 : eor #$FFFF : and !Pad4_temp : sta $2E : lda !Pad4_temp : sta $26
    bra .combine
.no_multitap:
    stz $4016
.no_multitap_strobed:
    rep #$20
    stz $26 : stz $2E               ; no P4
.combine:
    lda $20 : ora $22 : ora $24 : ora $26 : sta !Combined_held
    lda $28 : ora $2A : ora $2C : ora $2E : sta !Combined_new
    rtl
JoypadEnd:
assert JoypadEnd <= $00FFB0, "input code overflows bank $00 padding"

; Readers of the old combined-new word $002E -> !Combined_new (operand byte only;
; all eight were seen reading WRAM $002E at runtime, i.e. D=$0000).
org $00A8BA+1 : db !Combined_new
org $00F42C+1 : db !Combined_new
org $00F5BC+1 : db !Combined_new
org $029415+1 : db !Combined_new
org $04B1FF+1 : dw !Combined_new    ; LDA $002E (absolute)
org $04C47A+1 : db !Combined_new
org $04FA6E+1 : db !Combined_new
org $04FA77+1 : db !Combined_new
