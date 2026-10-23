; Per-player word array $19DC (2 words: P1,P2) relocated to 4 words at !PlayerWordArray.
; All executed references; operand-only changes (3-byte instructions).
!PlayerWordArray = $0110      ; $0110-$0117, free RAM

Pw_19DC = !PlayerWordArray
Pw_19DE = !PlayerWordArray+2

org $038BA9+1 : dw Pw_19DC   ; STZ $19DC
org $038BAC+1 : dw Pw_19DE   ; STZ $19DE
org $03A3F1+1 : dw Pw_19DC   ; LDA $19DC,Y
org $03A425+1 : dw Pw_19DC   ; STA $19DC,Y
org $03C288+1 : dw Pw_19DC   ; LDA $19DC,Y
org $03C423+1 : dw Pw_19DC   ; LDA $19DC,Y
org $03C42D+1 : dw Pw_19DC   ; STA $19DC,Y
org $03C491+1 : dw Pw_19DC   ; STA $19DC,Y
org $03C4CE+1 : dw Pw_19DC   ; LDA $19DC,Y
org $03C7DD+1 : dw Pw_19DC   ; LDA $19DC,Y
org $03C8AB+1 : dw Pw_19DC   ; LDA $19DC,Y
org $03C930+1 : dw Pw_19DC   ; LDA $19DC,Y
org $03CC18+1 : dw Pw_19DC   ; LDA $19DC,Y
org $03DC67+1 : dw Pw_19DC   ; LDA $19DC,Y
org $03DC79+1 : dw Pw_19DC   ; STA $19DC,Y
org $03DF02+1 : dw Pw_19DC   ; LDA $19DC,Y
org $03E055+1 : dw Pw_19DC   ; LDA $19DC,Y
org $03E05F+1 : dw Pw_19DC   ; STA $19DC,Y
org $03E096+1 : dw Pw_19DC   ; LDA $19DC,Y
org $03FA7E+1 : dw Pw_19DC   ; LDA $19DC,Y
org $0482A2+1 : dw Pw_19DC   ; LDA $19DC,Y
org $0482BA+1 : dw Pw_19DC   ; STA $19DC,Y
; Not executed in the recorded runs, but real code (clear both words; e.g. on
; stage transitions). Repointed as well. P3/P4 words are cleared separately (4P init).
org $00C861+1 : dw Pw_19DC   ; STZ $19DC
org $00C864+1 : dw Pw_19DE   ; STZ $19DE
org $028866+1 : dw Pw_19DC   ; STZ $19DC
org $028869+1 : dw Pw_19DE   ; STZ $19DE
