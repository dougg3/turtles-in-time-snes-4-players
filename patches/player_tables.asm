; Per-player lookup tables widened from 2 to 4 entries.
;
; The original tables in bank $01 hold exactly two words (P1, P2) and are followed
; by unrelated data, so 4-entry copies are placed in bank $01 padding ($01:FE1F,
; 481 bytes of $FF) and every indexed access is repointed. All accesses run with
; DB=$01 (runtime-checked at 9 of 23 sites; the rest are in the same player code).
; Index Y = player*2 (from $1864). P3/P4 entries are new; with one
; or two players Y is only ever 0 or 2, so 1P/2P behavior is unchanged
; (scripts/regress.sh). Proof of concept: P3/P4 share P1/P2's sprite VRAM
; (wrong graphics) until they get their own OBJ memory. $1F40-block and
; $8D6B-pointer meanings are unknown: P3/P4 get free RAM / copies of P2.

org $01FE20
PlayerCompanionA:   dw !P1_compA, !P2_compA, !P3_compA, !P4_compA   ; was $01:95D5 (slots 2/3)
PlayerCompanionB:   dw !P1_compB, !P2_compB, !P3_compB, !P4_compB   ; was $01:96C3 (slots 4/6)
PlayerInfoBlock:    dw $1A80, $1AC0, $1B20, $1B60   ; was $01:9CF7
PlayerWord19DC:     dw !PlayerWordArray, !PlayerWordArray+2, !PlayerWordArray+4, !PlayerWordArray+6   ; was $01:9D77: addresses of the per-player
                                                    ; word array, relocated $19DC -> !PlayerWordArray (player_word_array.asm)
PlayerBlock1F40:    dw $1F40, $1F50, !P3_block1F40, !P4_block1F40   ; was $01:9DB7 (meaning unknown)
PlayerPtr8D6B:      dw $8D6B, $8D6F, $8D6B, $8D6F   ; was $01:9DBB (meaning unknown)
PlayerCompanionB2:  dw !P1_compB, !P2_compB, !P3_compB, !P4_compB   ; was $01:9E0F
PlayerCompanionA2:  dw !P1_compA, !P2_compA, !P3_compA, !P4_compA   ; was $01:9FDB
PlayerCompanionB3:  dw !P1_compB, !P2_compB, !P3_compB, !P4_compB   ; was $01:9FDF
PlayerInfoBlock2:   dw $1A80, $1AC0, $1B20, $1B60   ; was $01:9FEB
PlayerVramBody:     dw $6000, $6300, $6000, $6300   ; was $01:C296
PlayerVramPiece2:   dw $0000, $0300, $0000, $0300   ; was $01:C29A (added to $6200)
PlayerSpawnOffsetX: dw $FFE8, $0018, $FFF4, $000C   ; was $01:9F19: start X offset; P3/P4 -$0C/+$0C (-$30 put P3 left of the playfield clamp)
PlayerDA50:         dw $0000, $0002, $0000, $0002   ; was $01:DA50 (meaning unknown; read at $04:AD5C
                                                    ; with DB presumed $01 — not observed). P3/P4 copy P1/P2.
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

%repoint($00DF02, PlayerSpawnOffsetX)
%repoint($00DF0B, PlayerSpawnOffsetX)
%repoint($04AD5C, PlayerDA50)
