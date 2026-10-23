; RAM map of the 3P/4P additions.
;
; Everything here is low WRAM ($0000-$1FFF, reachable with DP/absolute from any
; bank) that the original game never reads or writes in a 2P game (WRAM access
; maps of all 10 scenes, build/runs/ram).

; ---- player objects ----
!P1_slot   = $0400
!P2_slot   = $0470
!P3_slot   = $0630      ; pool slot 5 (never used by the original)
!P4_slot   = $0710      ; pool slot 7 (never used by the original)
!P1_compA  = $04E0
!P2_compA  = $0550
!P1_compB  = $05C0
!P2_compB  = $06A0
; P3/P4 companions live outside the object pool ($0400-$149F), so the enemy slots
; (11-19 with their companions 20-28 / 29-37) stay as in the original game.
; Only the player-region loops (player_region.asm) and the draw loops see them.
!P3_compA  = $0100      ; $0100-$016F
!P4_compA  = $0170      ; $0170-$01DF
!P3_compB  = $1530      ; $1530-$159F (inside free $1526-$15FF)
!P4_compB  = $1640      ; $1640-$16AF (free $1640-$16BF; draw list follows at $16C0)

; ---- info blocks ($40 bytes, like P1 $1A80 / P2 $1AC0) ----
!P1_info   = $1A80
!P2_info   = $1AC0
!P3_info   = $1B20
!P4_info   = $1B60

; ---- variables: $1A30-$1A7F (free; P1's info block starts at $1A80) ----
!P3_block1F40    = $1A30   ; 16 bytes, like P1 $1F40 / P2 $1F50
!P4_block1F40    = $1A40
!PlayerWordArray = $1A50   ; 4 words, was $19DC (2 words)
!PlayerHitFlags  = $1A58   ; 4 words, was $19B0 (2 words)
!Tgt_list        = $1A60   ; up to 4 candidate pointers
!Tgt_count       = $1A68
!Tgt_min         = $1A6A
!Tgt_max         = $1A6C
!Tgt_best        = $1A6E
!CamA            = $1A70   ; camera "leader" X
!CamB            = $1A72   ; camera "trailer" X
!P3_ptr          = $1A74   ; object pointer, like $9E/$A0 (0 = absent)
!P4_ptr          = $1A76
!PlayerMode      = $1A78   ; 0 = original game, 3 = three players, 4 = four players

; ---- direct page ----
!P3_char   = $D4           ; character (object type), like $D0/$D2
!P4_char   = $D8
