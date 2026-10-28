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

; ---- variables: $1BA0-$1BBF (after P4's info block). Not entirely free: the attract
; demo's input playback uses $1BA8-$1BB3 ($00:E138; not run in 3P/4P games) and the
; stage start clears $1BA8 ($00:AF02: resets one message timer, harmless); the
; Scene 9 boss uses $1BB8/$1BBA ($04:E58B) ----
!HudMsgPhase     = $1BA0   ; 4 words: compact HUD message alternation (PRESS/START, GAME/OVER)
!HudMsgTimer     = $1BA8   ; 4 words: GAME/OVER alternation timer
!InfoTmp         = $1BB0   ; scratch for info4.asm
!InfoCnt         = $1BB2
!CharCand        = $1BB4   ; CharFree4: candidate turtle
!CharOwn         = $1BB6   ; CharFree4: own player index * 2
; ($1BB8/$1BBA are not free: the Scene 9 boss uses them, $04:E58B)
if !JP
    ; Japan: its demo playback ($1B88-$1B93, cleared at stage start, $00:B057)
    ; and the Scene 9 boss ($1B98/$1B9A, $04:E6C2) sit $20 lower than in the USA
    ; version, inside P4's info block; $1D70-$1DAF is free in both. (Japan's Time
    ; Trial retry menu, $04:DCF8, uses $1B22 = P3 info +$02: one player only.)
    !P4_info     = $1D70
    ; Japan: $1BA0-$1BAE is its text routine's RAM (USA $1BC0-$1BCE, $02:969A),
    ; $1BB0-$1BBA its round select and title codes; $1BC0-$1BD7 has no code
    ; references there (it is what the text routine left)
    !HudMsgPhase = $1BC0
    !HudMsgTimer = $1BC8
    !InfoTmp     = $1BD0
    !InfoCnt     = $1BD2
    !CharCand    = $1BD4
    !CharOwn     = $1BD6
endif
!HudColP3        = $1D4A   ; P3 box color 1 (by turtle, as the original does for P1/P2)
!HudColP4        = $1D4C
!EndPlayers      = $1D58   ; P3/P4 (bits 2/3) of the game that just ended (final screen)
!FinTmp          = $1D5A

; ---- variables: $1C80-$1CFF (free) ----
!HudFrameOn      = $1C80   ; non-zero: the compact 4-box frame is on screen
!HudFadeK        = $1C82   ; NMI: screen fade (amount subtracted from each color channel)
!HudFadeTmp      = $1C84
!HudFadeOut      = $1C86
!HudFadeP3       = $1C88   ; NMI: faded P3/P4 box color 1
!HudFadeP4       = $1C8A
!Sel4State       = $1C8C   ; turtle select: 0 unchecked, 1 four-player select, 2 off,
                           ; 3 four-player select ended with nobody extra (back to 2P)
!SelHover        = $1C8E   ; turtles with a cursor on them (bit t), portraits in color
!SelTick         = $1C90   ; frame counter for the cursor animation
!SelCount        = $1C92   ; 4 words: cursors per turtle (display pass)
!SelSession      = $1C9A   ; P3/P4 in this game (bits $0004/$0008, as SelBit); new game: 0
!SelCont         = $1C9C   ; non-zero: the select screen after a continue (no joining)
; select4.asm scratch ($1CA0-$1CBF)
!SelCand         = $1CA0   ; candidate turtle
!SelDir          = $1CA2   ; step direction (1 or 3)
!SelLkTurtle     = $1CA4   ; SelLocked: turtle
!SelLkMe         = $1CA6   ; SelLocked: asking player
!SelHvTurtle     = $1CA8   ; SelHovered: turtle
!SelPad          = $1CAA   ; new buttons of the player being handled
!SelMe           = $1CAC   ; player index * 2 being handled
!SelTurtle       = $1CAE   ; turtle just confirmed / being drawn
!SelMask         = $1CB0   ; turtles with a cursor (this frame)
!SelChanged      = $1CB2
!SelPos          = $1CB4   ; position in a turtle's stack of cursors
!SelVar          = $1CB6   ; cursor frame variant (0 or $20)
!SelFrozen       = $1CB8   ; confirmed (cursor not animated)
!SelN            = $1CBA   ; frame copy: entries left
!SelChr          = $1CBC   ; character of the player being updated
!SelSwapped      = $1CBE   ; players whose cursor another player swapped this frame (SelBit)
; warp4.asm (high WRAM: $7F:1280-$7F:31FF is never used by the game)
!WarpN           = $7F2000 ; time warp: players in the game (0-4)
!WarpList        = $7F2002 ; their indexes * 2, in order (4 words)
; hud4.asm, same area
!HudCornerBuf    = $7F2010 ; corner tiles: rows 0-4 of a lives digit bottom (5 words)
!HudCornerPending = $7F201A ; corner tiles to write in the next vblank (HudQueueFrame)
; extensions4.asm: $1CC0-$1CDB (variables listed there); buffers $7E:7F00-$7F7F

; ---- direct page ----
!P3_char   = $D4           ; character (object type), like $D0/$D2
!P4_char   = $D8
