; Stage-clear cheer: one "COWABUNGA!" balloon, as in the original.
;
; In the cheer (player state $29, step $00:BBC0) each turtle jumps; the first one
; present also gets its companion B as the speech balloon and plays sound $72. The
; original's rule is two-player: P2 skips it when P1 is present ($0414 = P1's
; character), P1 never skips. P3/P4 always said it, so a 4P stage clear showed
; three overlapping balloons and the voice three times. Now a player skips it when
; any lower-numbered player is present. P1 and P2 take the original's paths, so
; 1P/2P games are unchanged.

org $248000

; ---- $00:BBCE (X = player object; Versus was handled before; was CPX #$0470 /
; BNE $BBD8 / LDA $0414 / BNE $BC0F) ----
CheerOnce4:
    cpx #!P1_slot : beq .say
    lda.w !P1_slot+$14 : bne .skip
    cpx #!P2_slot : beq .say
    lda.w !P2_slot+$14 : bne .skip
    cpx #!P3_slot : beq .say
    lda.w !P3_slot+$14 : bne .skip
.say:
    jml $00BBD8
.skip:
    jml $00BC0F

Cheer4End:
assert Cheer4End <= $24FFFF, "cheer4 code overflows bank $24"

org $00BBCE : jml CheerOnce4      ; 4 of the 10 bytes; the rest is never reached
