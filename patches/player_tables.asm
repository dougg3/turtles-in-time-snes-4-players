; Per-player lookup tables widened from 2 to 4 entries.
;
; The original tables in bank $01 hold exactly two words (P1, P2) and are followed
; by unrelated data, so 4-entry copies are placed in bank $01 padding ($01:FE1F,
; 481 bytes of $FF) and every indexed access is repointed. All accesses run with
; DB=$01 (runtime-checked at 9 of 23 sites; the rest are in the same player code).
; Index Y = player*2 (from $1864). P3/P4 entries are placeholders ($0000) until
; their slots/blocks are assigned; with two players Y is only ever 0 or 2, so this
; patch must not change behavior (verified by scripts/regress.sh).

org $01FE20
PlayerCompanionA:   dw $04E0, $0550, $0000, $0000   ; was $01:95D5 (slots 2/3)
PlayerCompanionB:   dw $05C0, $06A0, $0000, $0000   ; was $01:96C3 (slots 4/6)
PlayerInfoBlock:    dw $1A80, $1AC0, $0000, $0000   ; was $01:9CF7
PlayerWord19DC:     dw $19DC, $19DE, $0000, $0000   ; was $01:9D77 (meaning unknown)
PlayerBlock1F40:    dw $1F40, $1F50, $0000, $0000   ; was $01:9DB7 (meaning unknown)
PlayerPtr8D6B:      dw $8D6B, $8D6F, $0000, $0000   ; was $01:9DBB (meaning unknown)
PlayerCompanionB2:  dw $05C0, $06A0, $0000, $0000   ; was $01:9E0F
PlayerCompanionA2:  dw $04E0, $0550, $0000, $0000   ; was $01:9FDB
PlayerCompanionB3:  dw $05C0, $06A0, $0000, $0000   ; was $01:9FDF
PlayerInfoBlock2:   dw $1A80, $1AC0, $0000, $0000   ; was $01:9FEB
PlayerVramBody:     dw $6000, $6300, $0000, $0000   ; was $01:C296
PlayerVramPiece2:   dw $0000, $0300, $0000, $0000   ; was $01:C29A (added to $6200)
PlayerTablesEnd:
assert PlayerTablesEnd <= $01FFC0, "player tables overflow bank $01 padding"

; Repoint each access: replace the 16-bit operand of the 3-byte instruction.
macro repoint(addr, table)
  org <addr>+1
    dw <table>
endmacro

%repoint($00B2E5, PlayerCompanionA)
%repoint($00B6A2, PlayerCompanionA)
%repoint($00B6BD, PlayerCompanionA)
%repoint($00B79E, PlayerCompanionA)
%repoint($00B943, PlayerCompanionA)
%repoint($00BC3E, PlayerCompanionB)
%repoint($00C259, PlayerCompanionB)
%repoint($00C6AD, PlayerCompanionB)
%repoint($00C6FF, PlayerCompanionB)
%repoint($00C72D, PlayerCompanionB)
%repoint($00C844, PlayerInfoBlock2)
%repoint($00C856, PlayerInfoBlock2)
%repoint($00C995, PlayerCompanionA2)
%repoint($00C9AF, PlayerCompanionB3)
%repoint($00CE98, PlayerInfoBlock)
%repoint($00CEDC, PlayerInfoBlock)
%repoint($00CEE8, PlayerInfoBlock)
%repoint($00CFBD, PlayerWord19DC)
%repoint($00D4F5, PlayerBlock1F40)
%repoint($00D4F8, PlayerPtr8D6B)
%repoint($00D687, PlayerCompanionB2)
%repoint($04939B, PlayerVramBody)
%repoint($0493BC, PlayerVramPiece2)
