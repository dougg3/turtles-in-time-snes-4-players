; Player info state machine for four players: joining, continue countdown, turtle
; select, game over (info blocks $1A80/$1AC0/$1B20/$1B60).
;
; The state machine ($04:D3C3, states in info +$00) runs for a player whose object
; is absent. Its routines pick P1 or P2 with "CPX #$1A80" (info) or "CPX #$0400"
; (object); here they take all four players. HUD messages are drawn in the compact
; boxes in 3P/4P mode (hud4.asm). Fixes that apply in every mode: the 1P game-over
; branch into patched bytes ($00:CF2D) and the player-pointer clear ($00:CF3E).
; In 1P/2P every other hook replays the original instructions.

org $01FEA0                         ; bank $01 padding after player_tables.asm
assert PlayerTablesEnd <= $01FEA0, "player tables run into info4 tables"
InfoSelectMsg4: dw $E61B, $E627, $E61B, $E627   ; was $01:E764 ("1P/2P SELECT"; compact: SEL)
InfoObject4:    dw !P1_slot, !P2_slot, !P3_slot, !P4_slot   ; was $01:E7A6
InfoTablesEnd:
assert InfoTablesEnd <= $01FFC0, "info4 tables overflow bank $01 padding"

org $209000
assert Hud4End <= $209000, "hud4 code runs into info4"

; ---- helpers ----
; X = info block -> Y = player index * 2 (anything else -> 2, as the original). Keeps A, X.
InfoIndexY:
    cpx.w #!P1_info : beq .p1
    cpx.w #!P3_info : beq .p3
    cpx.w #!P4_info : beq .p4
    ldy #$0002
    rtl
.p1:
    ldy #$0000
    rtl
.p3:
    ldy #$0004
    rtl
.p4:
    ldy #$0006
    rtl

InfoPtrAddr: dw $009E, $00A0, !P3_ptr, !P4_ptr
InfoBlocks:  dw !P1_info, !P2_info, !P3_info, !P4_info

; Y = own index * 2 -> A = number of other players in the session: playing (object
; pointer set) or counting down to continue / choosing a turtle (state 2-4).
; Keeps X, Y; Z set if none.
OthersInSession:
    phx : phy
    sty !InfoTmp
    stz !InfoCnt
    ldx #$0000
.loop:
    cpx !InfoTmp : beq .next
    lda.l InfoPtrAddr,x : tay
    lda $0000,y : bne .in
    lda.l InfoBlocks,x : tay
    lda $0000,y
    cmp #$0002 : bcc .next
    cmp #$0005 : bcs .next
.in:
    inc !InfoCnt
.next:
    inx : inx
    cpx #$0008 : bcc .loop
    ply : plx
    lda !InfoCnt
    rts

; ---- compact messages (rows 2-3, cols 1-6 of the box, big font) ----
; 6 characters each: big-font codes $30-$3F (A C E G I L M N O P R S T U V W), 0 = blank
CompactStrings:
.blank: db $00, $00, $00, $00, $00, $00
.press: db $39, $3A, $32, $3B, $3B, $00
.start: db $3B, $3C, $30, $3A, $3C, $00
.game:  db $33, $30, $36, $32, $00, $00
.over:  db $38, $3E, $32, $3A, $00, $00
.cont:  db $31, $38, $37, $3C, $00, $00   ; countdown digit in col 6 (CountDigit)
.sel:   db $3B, $32, $35, $00, $00, $00   ; countdown digit in col 6
.wait:  db $3F, $30, $34, $3C, $00, $00
!MsgBlank = CompactStrings_blank-CompactStrings
!MsgPress = CompactStrings_press-CompactStrings
!MsgStart = CompactStrings_start-CompactStrings
!MsgGame  = CompactStrings_game-CompactStrings
!MsgOver  = CompactStrings_over-CompactStrings
!MsgCont  = CompactStrings_cont-CompactStrings
!MsgSel   = CompactStrings_sel-CompactStrings
!MsgWait  = CompactStrings_wait-CompactStrings

; A = original message string ($01:E5ED-$E64B), X = info -> compact message. Keeps X.
MsgCompact:
    phx
    pha
    jsr HudIndexX                   ; X = player index * 2
    pla
    cmp #$E60F : bne +              ; PRESS START: "PRESS" and "START" take turns
    lda.l !HudMsgPhase,x : eor #$0001 : sta.l !HudMsgPhase,x
    beq ++
    lda.w #!MsgPress
    bra .draw
++  lda.w #!MsgStart
    bra .draw
+   cmp #$E633 : bne +              ; GAME OVER: "GAME", then GameOverTick alternates
    lda #$0000 : sta.l !HudMsgPhase,x
    lda #$0030 : sta.l !HudMsgTimer,x
    lda.w #!MsgGame
    bra .draw
+   cmp #$E63F : bne +
    lda.w #!MsgCont
    bra .draw
+   cmp #$E61B : beq .sel
    cmp #$E627 : bne +
.sel:
    lda.w #!MsgSel
    bra .draw
+   cmp #$E5ED : bne +
    lda.w #!MsgWait
    bra .draw
+   lda.w #!MsgBlank
.draw:
    jsr DrawCompactMsg
    plx
    rts

; A = offset into CompactStrings, X = player index * 2. Clobbers A, X, Y, $10-$16.
DrawCompactMsg:
    sta $10
    lda.l HudAttr,x : sta $14
    lda.l HudLivesPos,x : sta $12   ; col 1, row 2
    stz $16 : jsr .row
    lda #$0010 : sta $16            ; bottom halves: char + $10, blank = border line
    lda $12 : clc : adc #$0020 : sta $12
    jsr .row
    rts
.row:
    ldy $12
    jsl Orig_VramAddr
    ldx $10
    lda #$0006 : sta $18
.char:
    lda.l CompactStrings,x : and #$00FF
    bne .glyph
    lda $16 : beq +
    lda #!HudBorderBot
    bra .put
+   lda #!HudBlankTile
    bra .put
.glyph:
    clc : adc $16 : ora $14
.put:
    phx
    jsl Orig_VramWord
    plx
    inx
    dec $18 : bne .char
    jsl Orig_VramClose
    rts

; A = digit 0-9 (or -1: blank), X = player index * 2: big digit in col 6, rows 2-3.
CountDigit:
    sta $10
    lda.l HudAttr,x : sta $14
    lda.l HudLivesPos,x : clc : adc #$0005 : pha
    tay
    jsl Orig_VramAddr
    lda $10 : bmi +
    clc : adc #$0050 : ora $14      ; big digit top: tile $150 + d
    bra ++
+   lda #!HudBlankTile
++  jsl Orig_VramWord
    jsl Orig_VramClose
    pla : clc : adc #$0020 : tay
    jsl Orig_VramAddr
    lda $10 : bmi +
    clc : adc #$0060 : ora $14      ; bottom: tile $160 + d
    bra ++
+   lda #!HudBorderBot
++  jsl Orig_VramWord
    jsl Orig_VramClose
    rts

; X = player index * 2: rows 2-3 of the box back to the empty frame (before lives and
; health bar are redrawn).
HudRestoreRows23:
    txa : asl #3 : clc : adc #$0080 : sta $10   ; template offset of row 2, col 8b
    txa : asl #2 : clc : adc #$5040 : sta $12   ; VRAM: row 2, col 8b
    jsr .row
    lda $10 : clc : adc #$0040 : sta $10
    lda $12 : clc : adc #$0020 : sta $12
.row:
    ldy $12
    jsl Orig_VramAddr
    ldx $10
    lda #$0008 : sta $18
-   lda.l HudFrameTemplate,x
    phx
    jsl Orig_VramWord
    plx
    inx : inx
    dec $18 : bne -
    jsl Orig_VramClose
    rts

; ---- message ($04:DBB7, A = string, X = info; was PHX / STA $10 / LDY #$0000) ----
Msg4:
    pha
    jsr HudCompact
    pla
    bcs .compact
    phx
    sta $10
    ldy #$0000
    jml $04DBBD
.compact:
    jsr MsgCompact
    rtl

; ---- "WAIT A MOMENT" ($04:D6A5, $10 = string; was LDY #0 / CPX #$1A80 / BEQ / INY INY) ----
WaitMsg4:
    jsr HudCompact : bcs .compact
    ldy #$0000
    cpx.w #!P1_info : beq +
    iny : iny
+   jml $04D6AF
.compact:
    lda $10
    jsr MsgCompact
    jml $04D6C0                     ; PLX / INC +$02 / RTL

; ---- turtle face (continue): none in the compact box ----
; $04:DC2F (was PHX / JSR $DC20) and $04:DC17 (clear; same bytes). $DC20: STA $10 /
; STZ $12 / Y = 0 (P1) or 2.
Face4:
    pha
    jsr HudCompact
    pla
    bcs .none
    phx
    jsr FaceIndex
    jml $04DC33
.none:
    rtl
FaceClear4:
    pha
    jsr HudCompact
    pla
    bcs .none
    phx
    jsr FaceIndex
    jml $04DC1B
.none:
    rtl
FaceIndex:
    sta $10
    stz $12
    ldy #$0000
    cpx.w #!P1_info : beq +
    iny : iny
+   rts

; ---- countdown digit ($04:D92C, X = info, digit = +$02; was PHX / LDA $0002,X) ----
Count4:
    jsr HudCompact : bcs .compact
    phx
    lda $0002,x
    jml $04D930
.compact:
    phx
    lda $0002,x : pha
    jsr HudIndexX
    pla
    jsr CountDigit
    plx
    rtl

; ---- countdown clear ($04:D95F, JSL; was JSR $D9D6 = STA $10 / Y index / $14 = attribute) ----
CountClear4:
    pha
    jsr HudCompact
    pla
    bcs .compact
    sta $10
    ldy #$0000
    cpx.w #!P1_info : beq +
    iny : iny
+   lda $E59B,y : sta $14           ; DB = $01, as the original
    jml $04D962
.compact:
    phx
    jsr HudIndexX
    lda #$FFFF
    jsr CountDigit
    plx
    rtl

; ---- respawn: clear the countdown area ($04:D58C, X = info, inside PHX/PLX;
; was Y index / LDX $E7FC,Y / JSL $009779) ----
RespawnClear4:
    jsr HudCompact : bcs .compact
    jsl InfoIndexY
    lda $E7FC,y : tax               ; DB = $01
    jml $009779
.compact:
    jsr HudIndexX
    jsr HudRestoreRows23            ; lives and health bar follow (info +$2C = 7)
    rtl

; ---- player character / pointer / effect for object X ----
StoreChar4:                         ; $04:D5E3: A = character -> $D0/$D2/$D4/$D8
    cpx.w #!P1_slot : beq .p1
    cpx.w #!P3_slot : beq .p3
    cpx.w #!P4_slot : beq .p4
    sta.w $00D2
    rtl
.p1:
    sta.w $00D0
    rtl
.p3:
    sta.w !P3_char
    rtl
.p4:
    sta.w !P4_char
    rtl

StorePtr4:                          ; $04:D609: X -> $9E/$A0/P3_ptr/P4_ptr
    cpx.w #!P1_slot : beq .p1
    cpx.w #!P3_slot : beq .p3
    cpx.w #!P4_slot : beq .p4
    stx.w $00A0
    rtl
.p1:
    stx.w $009E
    rtl
.p3:
    stx.w !P3_ptr
    rtl
.p4:
    stx.w !P4_ptr
    rtl

; $04:D5FC (JSL): character effect block $1F40/$1F50 ($04:8078/$808B). P3/P4: none yet
; (their own palettes come with the extension sprite memory).
PlayerFx4:
    cpx.w #!P1_slot : bne +
    jml $048078
+   cpx.w #!P3_slot : beq .none
    cpx.w #!P4_slot : beq .none
    jml $04808B
.none:
    rtl

ClearPtr4:                          ; $00:CF3E: object X is gone -> clear its pointer
    cpx.w #!P1_slot : beq .p1
    cpx.w #!P3_slot : beq .p3
    cpx.w #!P4_slot : beq .p4
    stz.w $00A0
    rtl
.p1:
    stz.w $009E
    rtl
.p3:
    stz.w !P3_ptr
    rtl
.p4:
    stz.w !P4_ptr
    rtl

; ---- out of lives ($00:CEC7, X = object; was LDA $00A8 / BEQ $CEFE) ----
; 2P: continue countdown in the box if the other player is still in the game ($A8),
; else the full-screen continue. 3P/4P: the same with "any other player".
DeathOut4:
    jsr HudFourMode : bcs .four
    lda.w $00A8 : bne .box
.screen:
    jml $00CEFE
.four:
    ldy $1864
    jsr OthersInSession
    beq .screen
.box:
    jml $00CECC

; ---- $00:CEFE: object X -> info block (was LDA #$1A80 / CPX #$0400 / BEQ / LDA #$1AC0 / TAX) ----
ObjToInfo4:
    cpx.w #!P1_slot : beq .p1
    cpx.w #!P3_slot : beq .p3
    cpx.w #!P4_slot : beq .p4
    ldx.w #!P2_info
    jml $00CF0A
.p1:
    ldx.w #!P1_info
    jml $00CF0A
.p3:
    ldx.w #!P3_info
    jml $00CF0A
.p4:
    ldx.w #!P4_info
    jml $00CF0A

; ---- $00:CF2D (one-player game over check; was LDA $000E,X / BRA $CF1B) ----
; $CF1B (BEQ $CF1F / BPL $CF25) now lies inside the OthersInPlay call at $00:CF18.
OneOut4:
    lda $000E,x
    beq .over
    bmi .over
    jml $00CF25
.over:
    jml $00CF1F

; ---- continue countdown ran out ($04:D570, X = info; was LDA $00A8 / BEQ $D579) ----
ContExpired4:
    jsr HudFourMode : bcs .four
    lda.w $00A8 : bne .box
.screen:
    jml $04D579                     ; game over for this player, then the full-screen check
.four:
    jsl InfoIndexY
    jsr OthersInSession
    beq .screen
.box:
    jml $04D575                     ; game over for this player only

; ---- game over ($04:D616, X = info; was STZ $00A8 / LDA #$E633) ----
; $A8 = two or more players in the game. 3P/4P: clear it only when fewer than two
; others remain.
GameOver4:
    jsr HudFourMode : bcs .four
    stz.w $00A8
    bra .msg
.four:
    jsl InfoIndexY
    jsr OthersInSession
    cmp #$0002 : bcs .msg
    stz.w $00A8
.msg:
    lda #$E633
    jml $04D61C

; ---- game-over box, every frame ($04:D634; was JSR $D644 / CMP $0030,X) ----
GameOverTick4:
    jsr HudCompact : bcc .cmp
    phx
    jsr HudIndexX
    lda.l !HudMsgTimer,x : dec : sta.l !HudMsgTimer,x
    bpl .done
    lda #$0030 : sta.l !HudMsgTimer,x
    lda.l !HudMsgPhase,x : eor #$0001 : sta.l !HudMsgPhase,x
    beq +
    lda.w #!MsgOver
    bra ++
+   lda.w #!MsgGame
++  jsr DrawCompactMsg
.done:
    plx
.cmp:
    jsl Other1A4
    cmp $0030,x : beq +
    jml $04D63C
+   jml $04D643                     ; RTL

; ---- $04:D644 (JSR): the other player's turtle. 3P/4P: own (no follow-up change) ----
Other1A4:
    jsr HudFourMode : bcs .own
    ldy.w #!P1_info
    cpx.w #!P1_info : bne +
    ldy.w #!P2_info
+   lda $001A,y
    rtl
.own:
    lda $001A,x
    rtl

; ---- join / character rules ($04:D45A; was LDA $00A8 / BNE $D488) ----
; 2P: only while one player is in the game. 3P/4P: straight to the join check
; ($04:D489: game mode allows it and the player presses START); on the one-player
; select (a 1P game with a multitap) the waiting boxes first follow P1's cursor.
JoinCheck4:
    jsr HudFourMode : bcs .four
    lda.w $00A8 : beq +
    jml $04D488                     ; RTL
+   jml $04D45F
.four:
    lda $70 : and #$00FF : cmp #$0002 : bne +
    lda.l !Sel4State : cmp #$0001 : beq +
    lda $0000,x : cmp #$0008 : bne +
    jsr OfferFree4
+   jml $04D489

; One-player select, X = info of a waiting box (state 8, WAIT A MOMENT): offer the
; first turtle from the box's own (P2 Mike, P3 Don, P4 Raph) that neither P1's cursor
; nor a lower waiting box has, as the original's P2 box shows P1's turtle + 1
; ($04:D45F) and as the boxes offer at stage start (HudAbsent4). Keeps X.
OfferFree4:
    phx
    jsl InfoIndexY
    sty !CharOwn
    tya : lsr : sta !CharCand       ; own default turtle
.try:
    lda.w !P1_info+$1A : and #$0003 : cmp !CharCand : beq .next
    ldy #$0002                      ; lower boxes, P2 up
-   cpy !CharOwn : bcs .ok
    tyx : lda.l InfoBlocks,x : tax
    lda $0000,x : cmp #$0008 : bne +
    lda $001A,x : and #$0003 : cmp !CharCand : beq .next
+   iny : iny
    bra -
.next:
    lda !CharCand : inc : and #$0003 : sta !CharCand
    bra .try
.ok:
    plx
    lda !CharCand : cmp $001A,x : beq +
    sta $001A,x
    phx
    jsl $04D561                     ; name (as $04:D483)
    plx
+   rts

; ---- joining ($04:D4A1, X = info; was LDA #$0004 / STA $0000,X) ----
; P3/P4 joining for the first time get the credits character select gives P1/P2.
; In 3P/4P anyone joining (also again after a game over) gets a turtle nobody else
; in the session has.
Join4:
    cpx.w #!P3_info : bne +
    lda #$0004
    bra .p34
+   cpx.w #!P4_info : bne ++
    lda #$0008
.p34:
    ora.l !SelSession : sta.l !SelSession   ; in this game (select4.asm, continue4.asm)
    lda $000E,x : bne ++
    lda #$0004 : sta $000E,x
    lda #$0001 : sta $0010,x
++  jsr HudFourMode : bcc ++       ; 3P/4P: anyone (re)joining gets a free turtle
    lda $001A,x
-   and #$0003
    jsr TurtleTaken
    bcc +
    inc
    bra -
+   sta $001A,x
++  lda #$0004 : sta $0000,x
    jml $04D4A7

; ---- turtle choice ($04:9705, A = candidate 0-3, X = info; was LDY $00A8 / BEQ $971B) ----
; 2P: not the other player's turtle while both are in the game. 3P/4P: not the turtle
; of any other player in the session.
CharFree4:
    pha
    jsr HudFourMode
    pla
    bcs .four
    ldy.w $00A8 : bne +
    jml $04971B                     ; free: store it
+   jml $04970A
.four:
    jsr TurtleTaken
    bcs +
    jml $04971B                     ; free: store it
+   jml $049720                     ; try the next one

; A = turtle 0-3, X = info -> carry set if another player in the session has it.
; Keeps A, X.
TurtleTaken:
    sta !CharCand
    phx
    jsl InfoIndexY
    sty !CharOwn
    ldx #$0000
.loop:
    cpx !CharOwn : beq .next
    lda.l InfoPtrAddr,x : tay
    lda $0000,y : bne .in           ; playing
    lda.l InfoBlocks,x : tay
    lda $0000,y
    cmp #$0002 : bcc .next
    cmp #$0005 : bcs .next          ; not counting down / choosing
.in:
    lda.l InfoBlocks,x : tay
    lda $001A,y
    cmp !CharCand : beq .taken
.next:
    inx : inx
    cpx #$0008 : bcc .loop
    plx
    lda !CharCand
    clc
    rts
.taken:
    plx
    lda !CharCand
    sec
    rts

; ---- $04:9812 (after a name change; X = info): P1/P2 box color by turtle, through
; the effect blocks $1F60/$1F70. P3/P4: their color is set with the name (HudName).
TurtlePal4:
    cpx.w #!P3_info : beq .none
    cpx.w #!P4_info : beq .none
    lda #$0000
    cpx.w #!P1_info
    jml $049818                     ; BEQ (P1) ...
.none:
    rtl

; ---- stage start (SpawnPlayers4), X = info of P3/P4 not in play: if it was in the
; game (out of it, or counting down), name and score in the new frame; if it never
; joined, the box offers a turtle nobody has, its name shown right away (as P2's in
; the original; the state machine only runs in play) ----
HudAbsent4:
    lda $000E,x : beq .free
    phx
    jsl $04AF7F                     ; name (Orig_InfoHud2)
    plx
    jsl $04D89B                     ; score
    rtl
.free:
    lda $001A,x
-   and #$0003
    jsr TurtleTaken
    bcc +
    inc
    bra -
+   sta $001A,x
    phx
    jsl $04AF7F                     ; name (Orig_InfoHud2)
    plx
    rtl

Info4End:
assert Info4End <= $210000, "info4 code overflows bank $20"

; ---- hooks ----
org $04D5F0                         ; was LDY #0 / CPX #$1A80 / BEQ / LDY #2 / RTS
    jsl InfoIndexY
    rts
org $04D523+1 : dw InfoSelectMsg4   ; LDA $E764,Y
org $04D5BA+1 : dw InfoObject4      ; LDX $E7A6,Y
org $04D58C                         ; was LDY #0 / CPX / ... / LDX $E7FC,Y / JSL $009779
    jsl RespawnClear4
    jml $04D59E
org $04D5E3                         ; was CPX #$0400 / BEQ / STA $D2 / RTS / STA $D0 / RTS
    jsl StoreChar4
    rts
org $04D5FC : jml PlayerFx4         ; was CPX #$0400 / BNE / JML $048078
org $04D609                         ; was CPX #$0400 / BEQ / STX $A0 / RTS / STX $9E / RTS
    jsl StorePtr4
    rts
org $04D644                         ; was LDY #$1A80 / CPX #$1A80 / BNE / LDY #$1AC0 / LDA $001A,Y / RTS
    jsl Other1A4
    rts
org $04D45A : jml JoinCheck4        ; was LDA $00A8 / BNE $D488
org $04D4A1                         ; was LDA #$0004 / STA $0000,X
    jml Join4
    nop : nop
org $04D570 : jml ContExpired4      ; was LDA $00A8 / BEQ $D579
org $04D616 : jml GameOver4         ; was STZ $00A8 / LDA #$E633
org $04D634 : jml GameOverTick4     ; was JSR $D644 / CMP $0030,X
org $04D6A5 : jml WaitMsg4          ; was LDY #$0000 / CPX #$1A80 ...
org $04DBB7 : jml Msg4              ; was PHX / STA $10 / LDY #$0000
org $04DC2F : jml Face4             ; was PHX / JSR $DC20
org $04DC17 : jml FaceClear4        ; was PHX / JSR $DC20
org $04D92C : jml Count4            ; was PHX / LDA $0002,X
org $04D95F : jml CountClear4       ; was JSR $D9D6 / LDA $E5E5,Y
org $049705 : jml CharFree4         ; was LDY $00A8 / BEQ $971B
org $049812 : jml TurtlePal4        ; was LDA #$0000 / CPX #$1A80
org $00CEC7 : jml DeathOut4         ; was LDA $00A8 / BEQ $CEFE
org $00CEFE : jml ObjToInfo4        ; was LDA #$1A80 / CPX #$0400 ...
org $00CF2D : jml OneOut4           ; was LDA $000E,X / BRA $CF1B
org $00CF3E                         ; was CPX #$0400 / BNE / STZ $9E / RTS / STZ $A0 / RTS
    jsl ClearPtr4
    rts
