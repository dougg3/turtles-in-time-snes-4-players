; Four-player HUD: compact boxes, four in one row.
;
; Active only in 3P/4P mode (!PlayerMode >= 3); in 1P/2P every hook replays the
; original instructions, so the original HUD is unchanged.
;
; Box b (player b+1) = BG3 columns 8b..8b+7, rows 0-3:
;   r0  badge digit (top)     border, score right-aligned in the border    corner
;   r1  badge digit (bottom)  name (4 chars)                               edge
;   r2  edge   lives (1 big digit)  gap  health bar (4 tiles)               edge
;   r3  corner lives (bottom)       line health bar (bottom)               corner
; Palettes: P1 1 (blue), P2 5 (orange) as the original; P3 6 (purple), P4 7 (red),
; loaded into CGRAM after the game's palette upload.

Orig_VramAddr  = $008D3E        ; Y = VRAM word address: start a queue entry
Orig_VramWord  = $008D74        ; A = word: append (clobbers X)
Orig_VramClose = $008D7F        ; close the queue entry
Orig_HudP1     = $04D39C        ; P1 part of the per-frame info/HUD driver $04:D34D
Orig_DrawBar   = $04D799
Orig_DrawScore = $04D89B
Orig_DrawLives = $04D9AC
Orig_NameNext  = $04D75D
Orig_BarNext   = $04D79D
Orig_ScoreNext = $04D89F
Orig_LivesNext = $04D9B2
Orig_StateMachine = $04D3C3     ; player info state machine (info4.asm)

!HudBlankTile  = $2100          ; tile $100 (blank), palette 0, priority
!HudBorderTop  = $255F          ; border line tiles, palette 1
!HudBorderBot  = $25F4

org $208000
; ---- helpers ----
; Carry set in 3P/4P mode (game rules for four players). Clobbers A.
HudFourMode:
    lda.l !PlayerMode : and #$00FF : cmp #$0003
    rts

; Carry set if the compact 4-box frame is on screen (3P/4P mode, drawn at stage
; start; the game-over and continue screens bring the 2-box HUD back). Clobbers A.
HudCompact:
    lda.l !HudFrameOn : beq +
    bra HudFourMode
+   clc
    rts

; X = info block -> X = player index * 2 (0/2/4/6); unknown -> 2 (P2, the original default).
HudIndexX:
    cpx.w #!P1_info : beq .p1
    cpx.w #!P3_info : beq .p3
    cpx.w #!P4_info : beq .p4
    ldx #$0002
    rts
.p1:
    ldx #$0000
    rts
.p3:
    ldx #$0004
    rts
.p4:
    ldx #$0006
    rts

; ---- tables (index = player * 2) ----
HudAttr:      dw $2500, $3500, $3900, $3D00   ; priority + palette 1/5/6/7 + tile bit 8
HudNamePos:   dw $5021, $5029, $5031, $5039   ; row 1, col 8b+1
HudScorePos:  dw $5003, $500B, $5013, $501B   ; row 0, cols 8b+3..8b+6
HudLivesPos:  dw $5041, $5049, $5051, $5059   ; rows 2-3, col 8b+1
HudBarPos:    dw $5043, $504B, $5053, $505B   ; rows 2-3, cols 8b+3..8b+6
HudBarTiles:  dw $007A, $007C, $007C, $007E   ; shade per bar tile: solid, dotted, dotted, white
HudPalCommon: dw $7FFF, $6940                 ; box colors 2-3: white, dark blue (all players)
; Box color 1 follows the turtle, as the original sets it for P1/P2 ($04:9812,
; measured in CGRAM): Leo, Mike, Don, Raph.
HudTurtleColor: dw $7F13, $02DF, $7E3F, $013F

; BG3 rows 0-3 (32 words each): frame and badges of the four boxes.
macro hudbox_r0(n, pal)
    dw $2000|(<pal><<10)|($150+<n>), !HudBorderTop, !HudBorderTop, !HudBorderTop
    dw !HudBorderTop, !HudBorderTop, !HudBorderTop, $25F0
endmacro
macro hudbox_r1(n, pal)
    dw $2000|(<pal><<10)|($160+<n>), !HudBlankTile, !HudBlankTile, !HudBlankTile
    dw !HudBlankTile, !HudBlankTile, !HudBlankTile, $25F1
endmacro
macro hudbox_r2()
    dw $256F, !HudBlankTile, !HudBlankTile, !HudBlankTile
    dw !HudBlankTile, !HudBlankTile, !HudBlankTile, $25F1
endmacro
macro hudbox_r3()
    dw $25F3, !HudBorderBot, !HudBorderBot, !HudBorderBot
    dw !HudBorderBot, !HudBorderBot, !HudBorderBot, $25F5
endmacro
HudFrameTemplate:
    %hudbox_r0(1, 1) : %hudbox_r0(2, 5) : %hudbox_r0(3, 6) : %hudbox_r0(4, 7)
    %hudbox_r1(1, 1) : %hudbox_r1(2, 5) : %hudbox_r1(3, 6) : %hudbox_r1(4, 7)
    %hudbox_r2() : %hudbox_r2() : %hudbox_r2() : %hudbox_r2()
    %hudbox_r3() : %hudbox_r3() : %hudbox_r3() : %hudbox_r3()
HudFrameTemplateEnd:
assert HudFrameTemplateEnd-HudFrameTemplate == 256, "HUD frame template must be 4 rows x 32 words"

; ---- frame: queue the compact frame (rows 0-3) to VRAM ----
; Called at stage start (SpawnPlayers4, before any HUD contents are drawn), after
; the scene's BG3 map (with the 2-player frame) has been uploaded. (Rewriting the
; map in the decompressor's buffer instead costs cycles in an idle-time job and
; shifts 2P timing.) Clobbers A, X, Y.
HudQueueFrame:
    jsr HudFourMode : bcc .done
    lda #$0001 : sta.l !HudFrameOn
    lda #$0000
.row:
    pha                             ; A = byte offset of the row in the template
    lsr : clc : adc #$5000 : tay    ; VRAM word address of the row
    jsl Orig_VramAddr
    pla : pha
    tax
.word:
    lda.l HudFrameTemplate,x
    phx
    jsl Orig_VramWord
    plx
    inx : inx
    txa : and #$003F : bne .word
    jsl Orig_VramClose
    pla : clc : adc #$0040
    cmp #$0100 : bcc .row
.done:
    rtl

; ---- palettes (NMI, $00:81C0, was JSL $008E09 = the game's HDMA setup) ----
; BG3 palettes 6 and 7 (CGRAM 25-27, 29-31) hold the P3/P4 HUD colors on lines
; 0-31 only; some scenes use these palettes for BG3 graphics lower down. (Not
; palette 3: the Mode 7 scene's own HDMA writes CGRAM 12/13 on every line.)
; An HDMA channel sets the HUD colors on lines 0-5 and restores the scene's
; colors (from the game's CGRAM buffer at [$42]) on lines 32-37. The HDMA table
; also covers lag frames, where the game's short NMI path skips this code. The
; colors are also written during vblank (line 0 is drawn before the first HDMA
; transfer takes effect).
; Channel: the highest one below the game's HDMA channels (7 down to [$1ED2]);
; GP-DMA uses channel 0. If none is free (Mode 7 scene: all eight in use), only
; the vblank write is done — BG3 is not shown below the HUD there.
!HudHdmaTable = $7E3E00             ; 61 bytes; WRAM never used by the game
Orig_HdmaSetup = $008E09

macro hud_color(cg, word)          ; CGRAM[cg] = word (vblank)
    lda #<cg> : sta $2121
    lda.l <word> : sta $2122
    lda.l <word>+1 : sta $2122
endmacro
macro hud_entry_rom(n, lines, cg, word)   ; HDMA entry n: CGRAM[cg] = word, then wait
    lda #<lines> : sta.l !HudHdmaTable+(5*<n>)
    lda #<cg> : sta.l !HudHdmaTable+(5*<n>)+1 : sta.l !HudHdmaTable+(5*<n>)+2
    lda.l <word> : sta.l !HudHdmaTable+(5*<n>)+3
    lda.l <word>+1 : sta.l !HudHdmaTable+(5*<n>)+4
endmacro
macro hud_color_buf(cg, src)       ; CGRAM[cg] = buffer color src (vblank; X = buffer)
    lda #<cg> : sta $2121
    lda.l $7E0000+(2*<src>),x : sta $2122
    lda.l $7E0001+(2*<src>),x : sta $2122
endmacro
macro hud_entry_buf(n, lines, cg, src)    ; HDMA entry n: CGRAM[cg] = buffer color src, then wait
    lda #<lines> : sta.l !HudHdmaTable+(5*<n>)
    lda #<cg> : sta.l !HudHdmaTable+(5*<n>)+1 : sta.l !HudHdmaTable+(5*<n>)+2
    lda.l $7E0000+(2*<src>),x : sta.l !HudHdmaTable+(5*<n>)+3
    lda.l $7E0001+(2*<src>),x : sta.l !HudHdmaTable+(5*<n>)+4
endmacro
macro hud_entry_scene(n, cg)        ; HDMA entry n: 1 line, CGRAM[cg] = scene color (X = buffer)
    lda #$01 : sta.l !HudHdmaTable+(5*<n>)
    lda #<cg> : sta.l !HudHdmaTable+(5*<n>)+1 : sta.l !HudHdmaTable+(5*<n>)+2
    lda.l $7E0000+(2*<cg>),x : sta.l !HudHdmaTable+(5*<n>)+3
    lda.l $7E0001+(2*<cg>),x : sta.l !HudHdmaTable+(5*<n>)+4
endmacro

HudNmi:
    jsl Orig_HdmaSetup
    php
    rep #$30
    pha
    jsr HudCompact : bcs .on
.done:
    pla
    plp
    rtl
.on:
    phx
    ldx $42                         ; X = the game's CGRAM buffer (bank $7E)
    lda.l $7E000C,x : and #$001F    ; P1 box color 2 (white) as faded by the game:
    eor #$001F : sta.l !HudFadeK    ; fade = 31 - red (subtracted from every channel)
    lda.l !HudColP3 : jsr HudFade : sta.l !HudFadeP3
    lda.l !HudColP4 : jsr HudFade : sta.l !HudFadeP4
    sep #$20                        ; A 8-bit, X/Y 16-bit
    lda $4212 : bpl .late           ; NMI ran past vblank (a long upload): CGRAM writes
    %hud_color(25, !HudFadeP3) : %hud_color_buf(26, 6) : %hud_color_buf(27, 7)
    %hud_color(29, !HudFadeP4) : %hud_color_buf(30, 6) : %hud_color_buf(31, 7)
.late:                              ; now would show as streaks on the top lines
    plx
    lda $1ED2 : cmp #$02 : bcs +
    jmp .nohdma
+   lda $1ED2
    cmp #$09 : bcc +
    lda #$08
+   dec                             ; channel = [$1ED2] - 1 (at most 7)
    pha
    ldx $42                         ; X = the game's CGRAM buffer (bank $7E)
    %hud_entry_rom(0, 1, 25, !HudFadeP3) : %hud_entry_buf(1, 1, 26, 6)
    %hud_entry_buf(2, 1, 27, 7) : %hud_entry_rom(3, 1, 29, !HudFadeP4)
    %hud_entry_buf(4, 1, 30, 6) : %hud_entry_buf(5, 27, 31, 7)
    %hud_entry_scene(6, 25) : %hud_entry_scene(7, 26) : %hud_entry_scene(8, 27)
    %hud_entry_scene(9, 29) : %hud_entry_scene(10, 30) : %hud_entry_scene(11, 31)
    lda #$00 : sta.l !HudHdmaTable+60
    pla
    rep #$20
    and #$0007 : asl #4 : tax       ; X = channel * 16
    sep #$20
    lda #$03 : sta $4300,x          ; mode 3: $2121, $2121, $2122, $2122
    lda #$21 : sta $4301,x
    lda.b #!HudHdmaTable : sta $4302,x
    lda.b #!HudHdmaTable>>8 : sta $4303,x
    lda.b #!HudHdmaTable>>16 : sta $4304,x
    txa : lsr #4 : tax              ; X = channel
    lda.l HudChannelBit,x
    ora $1ECA
    sta $420C
.nohdma:
    rep #$20
    pla
    plp
    rtl
HudChannelBit: db $01, $02, $04, $08, $10, $20, $40, $80

; A = color -> A = color with !HudFadeK subtracted from each channel (at least 0),
; as the game fades its palettes. 16-bit A.
HudFade:
    sta.l !HudFadeTmp
    lda.l !HudFadeK : bne +
    lda.l !HudFadeTmp
    rts
+   lda.l !HudFadeTmp : and #$001F
    sec : sbc.l !HudFadeK : bpl +
    lda #$0000
+   sta.l !HudFadeOut                         ; red
    lda.l !HudFadeTmp : lsr #5 : and #$001F
    sec : sbc.l !HudFadeK : bpl +
    lda #$0000
+   asl #5 : ora.l !HudFadeOut : sta.l !HudFadeOut   ; green
    lda.l !HudFadeTmp : xba : lsr #2 : and #$001F
    sec : sbc.l !HudFadeK : bpl +
    lda #$0000
+   xba : asl #2 : ora.l !HudFadeOut          ; blue
    rts

; ---- per-frame driver ($04:D34D, was JSL $04D39C): P1, then P3/P4 HUD updates ----
; Same rules as the original for P1/P2: while the player object exists, one dirty
; item per frame (info +$2C: bit 0 health bar, bit 1 score, else lives); otherwise
; the info state machine (join, continue, game over), then the score if dirty.
HudDriver4:
    jsl Orig_HudP1
    pha
    jsr HudCompact
    pla
    bcc .done
    pha : phx : phy
    ldx.w #!P3_info : ldy.w #!P3_slot : jsr .one
    ldx.w #!P4_info : ldy.w #!P4_slot : jsr .one
    ply : plx : pla
.done:
    rtl
.one:
    lda $0044 : bne .sm
    lda $0014,y : bne .present
.sm:                                ; player object absent: info state machine (info4.asm)
    lda $008C : cmp #$0004 : beq .ret   ; as P2 ($04:D351)
    phx
    jsl Orig_StateMachine
    plx
    lda $002C,x : bit #$0002 : beq .ret
    jsl Orig_DrawScore
    rts
.present:
    lda $186A : cmp #$0002 : bcs .ret
    lda $002C,x : beq .ret
    bit #$0001 : bne .bar
    bit #$0002 : bne .score
    jsl Orig_DrawLives
    rts
.bar:
    jsl Orig_DrawBar
    rts
.score:
    jsl Orig_DrawScore
.ret:
    rts

; ---- name ($04:D758, A = character * 2; was PHX / TAY / LDA $E5A3,Y) ----
HudName:
    pha
    jsr HudCompact : bcs .compact
    pla
    phx
    tay
    lda $E5A3,y                     ; DB = $01 here, as in the original
    jml Orig_NameNext
.compact:
    pla
    phx
    tay
    lda $E5A3,y : sta $10           ; name string, $FF-terminated (4 chars)
    jsr HudIndexX
    phx                             ; P3/P4: box color of this turtle
    tyx                             ; (Y = character * 2 = turtle * 2)
    lda.l HudTurtleColor,x
    plx : phx
    cpx #$0004 : bne +
    sta.l !HudColP3
+   cpx #$0006 : bne +
    sta.l !HudColP4
+   plx
    lda.l HudAttr,x : sta $14
    lda.l HudNamePos,x : tay
    jsl Orig_VramAddr
    stz $12
.char:
    ldy $12
    sep #$20
    lda ($10),y
    cmp #$FF : beq .end
    rep #$20
    and #$00FF : ora $14
    jsl Orig_VramWord
    inc $12
    bra .char
.end:
    rep #$20
    jsl Orig_VramClose
    plx
    rtl

; ---- score ($04:D89B, X = info; was PHX / LDA $001C,X): 4 BCD digits in the top
; border, leading zeros show the border line ----
HudScore:
    jsr HudCompact : bcs .compact
    phx
    lda $001C,x
    jml Orig_ScoreNext
.compact:
    phx
    lda $001C,x : sta $10
    jsr HudIndexX
    lda.l HudAttr,x : sta $14
    lda.l HudScorePos,x : tay
    jsl Orig_VramAddr
    lda #$1000 : sta $16 : lda $10 : xba : lsr #4 : and #$000F : jsr .digit
    lda #$0100 : sta $16 : lda $10 : xba : and #$000F : jsr .digit
    lda #$0010 : sta $16 : lda $10 : lsr #4 : and #$000F : jsr .digit
    stz $16 : lda $10 : and #$000F : jsr .digit
    jsl Orig_VramClose
    plx
    lda $002C,x : and #$FFFD : sta $002C,x
    rtl
.digit:                             ; A = digit; blank (border) if score < $16
    pha
    lda $10 : cmp $16
    pla
    bcs .show
    lda #!HudBorderTop
    bra .put
.show:
    clc : adc #$0001 : ora $14      ; small digits: tile $101 + d
.put:
    jsl Orig_VramWord
    rts

; ---- lives ($04:D9AC, X = info; was LDA $002C,X / AND #$FFFB): one big digit ----
HudLives:
    jsr HudCompact : bcs .compact
    lda $002C,x : and #$FFFB
    jml Orig_LivesNext
.compact:
    lda $002C,x : and #$FFFB : sta $002C,x
    phx
    lda $0020,x                     ; BCD lives
    cmp #$0010 : bcc +
    lda #$0009                      ; 10 or more: show 9
+   and #$000F : sta $10
    jsr HudIndexX
    lda.l HudAttr,x : sta $14
    lda.l HudLivesPos,x : pha
    tay
    jsl Orig_VramAddr
    lda $10 : clc : adc #$0050 : ora $14   ; big digit top: tile $150 + d
    jsl Orig_VramWord
    jsl Orig_VramClose
    pla : clc : adc #$0020 : tay
    jsl Orig_VramAddr
    lda $10 : clc : adc #$0060 : ora $14   ; bottom: tile $160 + d
    jsl Orig_VramWord
    jsl Orig_VramClose
    plx
    rtl

; ---- health bar ($04:D799, X = info; was PHX / LDA $0022,X): 4 tiles = 8 segments
; of 2 health units (health 0-16, a started segment is shown) ----
HudBar:
    jsr HudCompact : bcs .compact
    phx
    lda $0022,x
    jml Orig_BarNext
.compact:
    phx
    lda $0022,x : sta $10
    jsr HudIndexX
    lda.l HudAttr,x : sta $14
    lda.l HudBarPos,x : sta $12
    stz $16 : jsr .row              ; top row
    lda #$0010 : sta $16            ; bottom row: tile + $10
    lda $12 : clc : adc #$0020 : sta $12
    jsr .row
    plx
    lda $002C,x : and #$FFFE : sta $002C,x
    rtl
.row:
    ldy $12
    jsl Orig_VramAddr
    stz $18                         ; health units before this tile (0, 4, 8, 12)
.tile:
    lda $10 : sec : sbc $18
    bmi .empty
    beq .empty
    cmp #$0003 : bcs .two
    lda #$0001                      ; one segment: tile + 1
    bra .shade
.two:
    lda #$0000
.shade:
    pha
    lda $18 : lsr : tax
    pla
    clc : adc.l HudBarTiles,x
    clc : adc $16
    ora $14
    bra .put
.empty:
    lda $16 : beq +
    lda #!HudBorderBot
    bra .put
+   lda #!HudBlankTile
.put:
    jsl Orig_VramWord
    lda $18 : clc : adc #$0004 : sta $18
    cmp #$0010 : bcc .tile
    jsl Orig_VramClose
    rts
; ---- game mode change ($00:A606, A = new mode; was STA $70 / LDA #$0001) ----
; The game-over screen ($0D) and turtle select ($02) load their own BG3 map with the
; 2-box HUD, so the compact frame is gone until the next stage start (the continue
; screen $0E keeps the stage's HUD). Turtle select not reached from the continue
; screen starts a new game: player count back to 2, P3/P4 out (they join on the
; select screen, select4.asm). From the continue screen of a 3P/4P game: the
; four-player select for those who continued. A four-player select that nobody
; extra joined ends in a 2-player game.
HudModeSet:
    pha
    lda.l !Sel4State : cmp #$0003 : bne +
    lda.l !PlayerMode : and #$FF00 : sta.l !PlayerMode
    lda #$0000 : sta.l !Sel4State : sta.l !HudFrameOn
+   pla
    cmp #$000D : beq .off
    cmp #$0002 : bne .set
    pha
    lda $70 : cmp #$000E : bne +
    lda #$0002 : sta.l !Sel4State   ; after a continue: the original select,
    lda.l !PlayerMode : and #$00FF : cmp #$0003 : bcc ++
    lda #$0000 : sta.l !Sel4State   ; or in a 3P/4P game the four-player one
    inc : sta.l !SelCont            ; for those who continued
    bra ++
+   lda #$0000
    sta.l !Sel4State
    sta.l !SelCont : sta.l !SelSession
    sta.l !P3_ptr : sta.l !P4_ptr
    sta.l !P3_info+$0E : sta.l !P4_info+$0E
    lda.l !PlayerMode : and #$FF00 : sta.l !PlayerMode
++  pla
.off:
    pha
    lda #$0000 : sta.l !HudFrameOn
    pla
.set:
    sta $70
    lda #$0001
    jml $00A60B

Hud4End:
assert Hud4End <= $210000, "hud4 code overflows bank $20"

; ---- hooks ----
org $0081C0 : jsl HudNmi            ; was JSL $008E09
org $00A606                         ; was STA $70 / LDA #$0001
    jml HudModeSet
    nop
org $04D34D : jsl HudDriver4        ; was JSL $04D39C
org $04D758                         ; was PHX / TAY / LDA $E5A3,Y
    jml HudName
    nop
org $04D89B : jml HudScore          ; was PHX / LDA $001C,X
org $04D9AC                         ; was LDA $002C,X / AND #$FFFB
    jml HudLives
    nop : nop
org $04D799 : jml HudBar            ; was PHX / LDA $0022,X
