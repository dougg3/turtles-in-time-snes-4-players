; Turtle select for up to four players.
;
; In a 2-player game with a multitap on port 2, the select screen shows the 4-box
; HUD; P3/P4 join by pressing START (their boxes say PRESS START). Once anyone
; extra has joined, choosing follows four-player rules:
;   - moving goes to the next turtle nobody else is on or has confirmed; with no
;     such turtle (four cursors), the cursor swaps with the next unconfirmed one
;     (user's design, 2026-10-24), so two cursors never share a turtle;
;   - confirming locks the turtle: other cursors skip it (any cursor still on it,
;     possible only from older rules, moves on to the next free turtle);
;   - at time-out, unconfirmed players keep their turtle if it is free, else take
;     the next free one.
; After a continue in a game with P3/P4 the same select runs for the players who
; continued (no joining). Without a multitap, in a 1-player game, and after a
; continue in a 2-player game, the original select runs unchanged (two cursors
; never share a turtle).
;
; Cursors are objects (P1/P2 companion B $05C0/$06A0, here also P3/P4's); a turtle
; portrait is in color while any cursor is on it (one effect block per turtle,
; $1F20 + $10 * turtle). Cursors sharing a turtle: the lowest player shows the
; full cursor (band + tag), the others only their tag, beside it on the same row
; (lower down a tag would overlap the band: the band's lower OAM index wins and
; puts both behind the portrait).

Orig_SelInput   = $04964E       ; P1/P2 select input (original)
Orig_CursorAnim = $04D2A7       ; X = cursor object: animation step
Orig_ObjClear   = $008BCD       ; X = object: clear $70 bytes
Orig_Sound      = $00839D       ; A = sound command
Orig_PalScript  = $00A155       ; X = effect block, Y = script
Orig_VramDirect = $008D8D       ; A = source, $00 = bank, Y = VRAM word, X = bytes
Orig_P1Turtle   = $049731       ; P1: name, object +$14, $D0 from info +$1A
Orig_P2Turtle   = $04974B
Orig_BoxColor  = $049812       ; X = info: box color by turtle (P1/P2)
Orig_InfoName   = $04D758       ; A = turtle * 2, X = info

!SndMove    = $005F
!SndConfirm = $0060
!CursorY    = $0090

; WRAM frames (bank $7E; the select screen's own frames end at $7E:833E)
!FrP3A = $9000                  ; full cursors (band + tag), copies of P2's
!FrP3B = $90D0
!FrP4A = $91A0
!FrP4B = $9270
!FrTag = $9340                  ; tag-only frames: player * $40 + variant * $20
!FrP2A = $81A6                  ; P2's frames on this screen
!FrP2B = $8272
!FrP1A = $8000
!FrP1B = $80D3

org $20A000
assert Info4End <= $20A000, "info4 code runs into select4"

SelInfo:    dw !P1_info, !P2_info, !P3_info, !P4_info
SelCursor:  dw !P1_compB, !P2_compB, !P3_compB, !P4_compB
SelObject:  dw !P1_slot, !P2_slot, !P3_slot, !P4_slot
SelPtr:     dw $009E, $00A0, !P3_ptr, !P4_ptr
SelChar:    dw $00D0, $00D2, !P3_char, !P4_char
SelPadNew:  dw $0028, $002A, $002C, $002E
SelFullA:   dw !FrP1A, !FrP2A, !FrP3A, !FrP4A
SelFullB:   dw !FrP1B, !FrP2B, !FrP3B, !FrP4B
SelFirst:   dw 0, 1, 2, 3        ; preferred turtle when joining
SelBit:     dw $0001, $0002, $0004, $0008
; X offsets of the 2nd-4th tag on a turtle (tags are 32 px wide; kept on screen)
SelSlotX:   dw 32, -32, 64          ; Leo   (x $28)
            dw 32, -32, 64          ; Mike  (x $68)
            dw 32, -32, -64         ; Don   (x $A8)
            dw -32, -64, -96        ; Raph  (x $E0)
; cursor colors 10/11 (P1 blue and P2 orange are the game's): P3 purple, P4 green
SelColP3:   dw $6092, $7D9A
SelColP4:   dw $1202, $2348

; tag-only frames: count, then entries of dx(16) dy(16) tile attr size; each frame
; padded to 32 bytes, copied as one block to !FrTag (player * $40 + variant * $20).
; Priority 3 ($30): stacked tags sit over the portraits.
macro tagentry(dx, dy, tile, attr, size)
    dw <dx>, <dy>
    db <tile>, <attr>, <size>
endmacro
macro tagframe2(dtile, dattr, dx, dy, pal)    ; 16x16 digit + "UP" bubble (22 bytes)
    db 3 : %tagentry(<dx>, <dy>, <dtile>, <dattr>|$30, 1)
    %tagentry(15, -84, $06, <pal>|$30, 1) : %tagentry(-1, -84, $04, <pal>|$30, 1)
    db 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
endmacro
SelTagFrames:
    db 4 : %tagentry(6, -76, $18, $30, 0) : %tagentry(6, -84, $08, $30, 0)      ; P1 A
    %tagentry(15, -84, $06, $30, 1) : %tagentry(-1, -84, $04, $30, 1)
    db 0, 0, 0
    db 4 : %tagentry(6, -78, $1B, $30, 0) : %tagentry(6, -86, $0B, $30, 0)      ; P1 B
    %tagentry(15, -84, $06, $30, 1) : %tagentry(-1, -84, $04, $30, 1)
    db 0, 0, 0
    %tagframe2($09, $02, 2, -84, $02)       ; P2 A
    %tagframe2($0C, $02, 1, -86, $02)       ; P2 B
    %tagframe2($70, $05, 2, -84, $04)       ; P3 A (tile $170)
    %tagframe2($72, $05, 1, -86, $04)       ; P3 B
    %tagframe2($74, $07, 2, -84, $06)       ; P4 A
    %tagframe2($76, $07, 1, -86, $06)       ; P4 B
SelTagFramesEnd:
assert SelTagFramesEnd-SelTagFrames == $100, "tag frames must be 8 x 32 bytes"

incsrc "select4_glyphs.asm"

; ---- helpers ----
; Carry set if a multitap is on port 2 (SNESdev wiki "Multitap", as input4.asm).
DetectMultitap:
    php
    sep #$20
-   lda $4212 : lsr : bcs -         ; not during the auto-read
    lda #$01 : sta $4016
    lda $4017 : and #$02 : beq .no
    stz $4016
    ldx #$0008
    ldy #$0000
-   lda $4017 : and #$02 : beq +
    iny
+   dex : bne -
    cpy #$0008 : beq .no2
    plp
    sec
    rts
.no:
    stz $4016
.no2:
    plp
    clc
    rts

; X = player index * 2 -> carry set if that player takes part in this select. Keeps X.
SelJoined:
    phx
    lda.l SelInfo,x : tax
    lda $000E,x
    plx
    cpx #$0004 : bcs .p34
    cmp #$8000 : bcs .no            ; P1/P2: info +$0E >= 0 (P2 only in a 2P game)
    cpx #$0002 : bne .yes
    lda $00E0 : beq .no
.yes:
    sec
    rts
.p34:
    cmp #$8000 : bcs .no            ; P3/P4: +$0E >= 0 and joined this game
    lda !SelSession : and.l SelBit,x : beq .no
    sec
    rts
.no:
    clc
    rts

; A = turtle, X = player index * 2 -> carry set if another taking-part player has
; confirmed that turtle. Keeps X.
SelLocked:
    sta !SelLkTurtle
    stx !SelLkMe
    phx
    ldx #$0000
.loop:
    cpx !SelLkMe : beq .next
    jsr SelJoined : bcc .next
    phx
    lda.l SelInfo,x : tax
    lda $0010,x : beq +
    lda $001A,x : cmp !SelLkTurtle : bne +
    plx
    plx
    lda !SelLkTurtle
    sec
    rts
+   plx
.next:
    inx : inx
    cpx #$0008 : bcc .loop
    plx
    lda !SelLkTurtle
    clc
    rts

; A = turtle -> carry set if any taking-part player's cursor is on it. Keeps A, X.
SelHovered:
    sta !SelHvTurtle
    phx
    ldx #$0000
.loop:
    jsr SelJoined : bcc .next
    phx
    lda.l SelInfo,x : tax
    lda $001A,x
    plx
    cmp !SelHvTurtle : beq .yes
.next:
    inx : inx
    cpx #$0008 : bcc .loop
    plx
    lda !SelHvTurtle
    clc
    rts
.yes:
    plx
    lda !SelHvTurtle
    sec
    rts

; X = player index * 2, A = direction (1 right, 3 left): move to the next turtle in
; that direction that nobody else is on or has confirmed; if there is none (all four
; cursors in), swap with the next unconfirmed one: that player's cursor takes this
; turtle (SelSwapped: it can't confirm this frame). Confirmed turtles are skipped;
; with nowhere to go the cursor stays. Info +$1A = turtle, +$10 = confirmed. Keeps X.
SelStep:
    sta !SelDir
    jsr SelMyTurtle : sta !SelCand
    ldy #$0003
-   lda !SelCand : clc : adc !SelDir : and #$0003 : sta !SelCand
    jsr SelLocked : bcs +
    jsr SelHovered : bcc .move      ; free
+   dey : bne -
    jsr SelMyTurtle : sta !SelCand  ; no free turtle: the next unconfirmed one
    ldy #$0003
-   lda !SelCand : clc : adc !SelDir : and #$0003 : sta !SelCand
    jsr SelLocked : bcc .swap
    dey : bne -
    rts                             ; all others confirmed: stay
.swap:
    stx !SelMe
    ldx #$0000                      ; whose cursor is on it
-   cpx !SelMe : beq +
    jsr SelJoined : bcc +
    phx
    lda.l SelInfo,x : tax
    lda $001A,x
    plx
    cmp !SelCand : beq ++
+   inx : inx
    cpx #$0008 : bcc -
    ldx !SelMe                      ; (nobody: can't happen)
    bra .move
++  phx                             ; X = the other player: gets my turtle
    ldx !SelMe
    jsr SelMyTurtle
    plx
    phx
    pha
    lda.l SelInfo,x : tax
    pla : sta $001A,x
    plx
    lda.l SelBit,x : ora !SelSwapped : sta !SelSwapped
    lda #$0000 : jsr SelMoved       ; its name and box (no sound)
    ldx !SelMe
.move:
    phx
    lda.l SelInfo,x : tax
    lda !SelCand : sta $001A,x
    plx
    rts

; X = player index * 2 -> A = its turtle (info +$1A). Keeps X.
SelMyTurtle:
    phx
    lda.l SelInfo,x : tax
    lda $001A,x
    plx
    rts

; X = player index * 2: turtle changed -> name, box color, character; A != 0: sound.
; Keeps X.
SelMoved:
    pha
    phx
    cpx #$0002 : bcs +
    jsl Orig_P1Turtle               ; P1: name, object +$14, $D0
    ldx.w #!P1_info : jsl Orig_BoxColor
    bra .snd
+   bne +
    jsl Orig_P2Turtle
    ldx.w #!P2_info : jsl Orig_BoxColor
    bra .snd
+   lda.l SelInfo,x : tax           ; P3/P4: name (and box color, HudName)
    lda $001A,x : asl
    jsl Orig_InfoName
    lda $001A,x : inc : asl : sta !SelChr   ; character = (turtle + 1) * 2
    lda $01,s : tax                 ; player index (pushed above)
    lda.l SelObject,x : tax
    lda !SelChr : sta $0014,x
    lda $01,s : tax
    lda.l SelChar,x : tax
    lda !SelChr : sta $0000,x
.snd:
    plx
    pla
    beq +
    lda.w #!SndMove : jsl Orig_Sound
+   rts

; ---- per frame ($04:9571, was JSL $04964E: P1/P2 select input) ----
Sel4Frame:
    lda !Sel4State : bne +
    jsr Sel4Check
+   lda !Sel4State : cmp #$0001 : beq +
    jml Orig_SelInput
+   inc !SelTick
    stz !SelSwapped
    ldx #$0000
.player:
    jsr Sel4Player
    inx : inx
    cpx #$0008 : bcc .player
    jsr Sel4Portraits
    jsr Sel4Cursors
    rtl

; First frame of the select loop: four-player select if it can be used.
Sel4Check:
    lda !SelCont : beq +            ; after a continue in a 3P/4P game
    lda #$0001 : sta !Sel4State
    jmp Sel4EnterCont
+   lda #$0002 : sta !Sel4State     ; off unless...
    lda $0056 : beq .one            ; "1 PLAYER" or "2 PLAYERS" from the title menu
    cmp #$0001 : bne .done          ; (not Versus, $56 = 4, which also has $E0 set)
    lda $00E0 : beq .done           ; a 2-player game
    jsr DetectMultitap : bcc .done  ; with a multitap
    lda #$0001 : sta !Sel4State
    jsr Sel4Enter
.done:
    rts
.one:                               ; a 1-player game with a multitap: the original
    jsr DetectMultitap : bcc .done  ; select for P1 (state 2), but a four-player game
    jmp Sel4EnterOne                ; P2-P4 can join in play, as P2 can in the original

Sel4Enter:
    jsr Sel4Mode
    ldx.w #!P3_info : jsr .info     ; P3/P4 boxes: PRESS START on this screen
    ldx.w #!P4_info : jsr .info
    jsl HudQueueFrame               ; 4-box HUD; P1/P2 contents again
    ldx.w #!P1_info : jsr .redraw
    lda $00E0 : beq +
    ldx.w #!P2_info : jsr .redraw
+   jsr Sel4Frames
    jsr Sel4Graphics
    lda.w !P1_info+$1A : asl : tax : lda.l SelBit,x : sta !SelHover   ; in color already
    lda.w !P2_info+$1A : asl : tax : lda.l SelBit,x : ora !SelHover : sta !SelHover
    rts
.info:                              ; X = info block (zeroed by Sel4Mode): the box
    lda #$0001 : sta $000C,x        ; state machine shows PRESS START on this screen
    rts                             ; (+$0C, $04:D43D)

.redraw:
    phx
    jsl $04AF7F                     ; name
    plx
    lda $002C,x : ora #$0007 : sta $002C,x   ; lives, bar, score follow
    rts

; 1-player game with a multitap: four-player game, original select for P1. P2-P4
; boxes say WAIT A MOMENT here (as P2's in the original) and PRESS START in play.
Sel4EnterOne:
    jsr Sel4Mode
    jsl HudQueueFrame               ; 4-box HUD; P1's contents again
    ldx.w #!P1_info : jsr Sel4Enter_redraw
    rts

; Four-player game from this select on: P3/P4 out (info zeroed, offering Don and
; Raph), objects cleared, nobody extra yet.
Sel4Mode:
    lda.l !PlayerMode : and #$FF00 : ora #$0003 : sta.l !PlayerMode
    ldx.w #!P3_info : jsr .zero
    ldx.w #!P4_info : jsr .zero
    lda #$0002 : sta.w !P3_info+$1A ; their boxes offer Don and Raph
    lda #$0003 : sta.w !P4_info+$1A
    lda #$0000 : sta.l !P3_ptr : sta.l !P4_ptr
    sta !SelSession
    ldx.w #!P3_slot : jsl Orig_ObjClear
    ldx.w #!P4_slot : jsl Orig_ObjClear
    ldx.w #!P3_compA : jsl Orig_ObjClear
    ldx.w #!P4_compA : jsl Orig_ObjClear
    ldx.w #!P3_compB : jsl Orig_ObjClear
    ldx.w #!P4_compB : jsl Orig_ObjClear
    rts
.zero:
    ldy #$0020
-   stz $0000,x
    inx : inx
    dey : bne -
    rts

; P3/P4 full cursor frames: P2's in their palette with their digit. Tag-only frames.
macro copyframe(src, dst, pal, digit)
    ldx.w #<src>
    lda.l $7E0000,x : sta.l $7E0000+<dst>-<src>,x
    sta !SelN
?entry:
    inx : lda.l $7E0000,x : sta.l $7E0000+<dst>-<src>,x   ; dx
    inx : lda.l $7E0000,x : sta.l $7E0000+<dst>-<src>,x
    inx : lda.l $7E0000,x : sta.l $7E0000+<dst>-<src>,x   ; dy
    inx : lda.l $7E0000,x : sta.l $7E0000+<dst>-<src>,x
    inx : lda.l $7E0000,x : sta.l $7E0000+<dst>-<src>,x   ; tile
    inx : lda.l $7E0000,x : and #$F1 : ora #<pal> : sta.l $7E0000+<dst>-<src>,x
    inx : lda.l $7E0000,x : sta.l $7E0000+<dst>-<src>,x   ; size
    dec !SelN : bne ?entry
    lda #<digit> : sta.l $7E0000+<dst>+5      ; entry 0 is the digit: tile, palette
    lda #<pal>|1 : sta.l $7E0000+<dst>+6      ; + tile bit 8 (tiles $170-$177)
endmacro
Sel4Frames:
    sep #$20
    %copyframe(!FrP2A, !FrP3A, $04, $70)
    %copyframe(!FrP2B, !FrP3B, $04, $72)
    %copyframe(!FrP2A, !FrP4A, $06, $74)
    %copyframe(!FrP2B, !FrP4B, $06, $76)
    rep #$20
    ldx #$00FE
-   lda.l SelTagFrames,x : sta.l $7E0000+!FrTag,x
    dex : dex : bpl -
    rts

; Digit tiles $170-$177 / $180-$187 (sprite table 2) and cursor palettes 2/3.
Sel4Graphics:
    lda.w #SelGlyphTop>>16 : sta $00
    lda.w #SelGlyphTop : ldy #$7700 : ldx #$0100 : jsl Orig_VramDirect
    lda.w #SelGlyphBottom>>16 : sta $00
    lda.w #SelGlyphBottom : ldy #$7800 : ldx #$0100 : jsl Orig_VramDirect
    ldx #$001E                      ; palettes 2/3 = palette 0 with the player colors
-   lda.l $7E3300,x : sta.l $7E3340,x : sta.l $7E3360,x
    dex : dex : bpl -
    lda.l SelColP3 : sta.l $7E3340+20
    lda.l SelColP3+2 : sta.l $7E3340+22
    lda.l SelColP4 : sta.l $7E3360+20
    lda.l SelColP4+2 : sta.l $7E3360+22
    lda $0040 : ora #$8000 : sta $0040  ; upload the color buffer
    rts

; ---- one player (X = index * 2; kept) ----
Sel4Player:
    stx !SelMe
    jsr SelJoined : bcs .in
    cpx #$0004 : bcc .done          ; P3/P4 not in yet: START joins
    lda !SelCont : bne .done        ; (not after a continue)
    lda.l SelPadNew,x : tay
    lda $0000,y : bit #$1000 : beq .done
    jsr Sel4Join
    ldx !SelMe
    rts
.in:
    lda.l SelInfo,x : tax
    lda $0010,x
    ldx !SelMe
    cmp #$0000 : bne .done          ; confirmed
    lda !SelSwapped : and.l SelBit,x : bne .done    ; just swapped: not this frame
    lda.l SelPadNew,x : tay
    lda $0000,y : sta !SelPad
    bit #$D0F0 : bne .confirm       ; as the original ($04:9603)
    lda !SelPad : and #$0300 : beq .done
    cmp #$0100 : beq +
    lda #$0003                      ; left
    bra ++
+   lda #$0001                      ; right
++  jsr SelStep
    lda #$0001
    jsr SelMoved
.done:
    rts
.confirm:
    lda.l SelInfo,x : tax
    lda #$0001 : sta $0010,x
    lda $001A,x : sta !SelTurtle
    lda.w #!SndConfirm : jsl Orig_Sound
    ldx #$0000                      ; others still on this turtle move on
.other:
    cpx !SelMe : beq .next
    jsr SelJoined : bcc .next
    phx
    lda.l SelInfo,x : tax
    lda $0010,x : bne +
    lda $001A,x : cmp !SelTurtle : bne +
    plx
    lda #$0001 : jsr SelStep
    lda #$0000 : jsr SelMoved
    bra .next
+   plx
.next:
    inx : inx
    cpx #$0008 : bcc .other
    ldx !SelMe
    rts

; ---- P3/P4 joins (X = index * 2 = !SelMe) ----
Sel4Join:
    lda.l SelBit,x : ora !SelSession : sta !SelSession
    lda.l SelFirst,x : sta !SelCand ; a turtle nobody is on, else one nobody confirmed
    ldy #$0004
-   lda !SelCand : jsr SelHovered : bcc .free
    inc : and #$0003 : sta !SelCand
    dey : bne -
    lda.l SelFirst,x : sta !SelCand
    jsr SelLocked : bcc .free
.free:
    lda.l SelInfo,x : tax
    lda #$0004 : sta $000E,x        ; credits, as character select gives P1/P2
    ldx !SelMe
    jsr Sel4Seat
    lda.w #!SndConfirm : jsl Orig_Sound
    ldx !SelMe
    rts

; P3/P4 (X = index * 2 = !SelMe) takes part with turtle !SelCand: as the select setup
; does for P1/P2 ($04:977F): lives, health, score, player object and pointer; cursor.
Sel4Seat:
    lda.l SelInfo,x : tax
    jsl Orig_InfoInit               ; lives, health, score
    lda !SelCand : sta $001A,x
    stz $0010,x                     ; not confirmed
    stz $0000,x
    stz $000C,x
    lda $002C,x : ora #$0007 : sta $002C,x   ; lives, bar, score
    ldx !SelMe
    lda !SelCand : jsr SelLocked : bcc +     ; (all others confirmed it: next free)
    lda #$0001 : jsr SelStep
+   lda.l SelObject,x : tax         ; player object (as P1/P2 have here) and pointer
    jsl Orig_ObjClear
    txa
    ldx !SelMe
    pha
    lda.l SelPtr,x : tax
    pla : sta $0000,x
    ldx !SelMe
    lda.l SelCursor,x : tax         ; cursor object
    jsl Orig_ObjClear
    lda.w #!CursorY : sta $0C,x
    lda #$0888 : sta $04,x
    ldx !SelMe
    jsr HudRestoreRows23            ; box: empty rows 2-3 (no PRESS START)
    ldx !SelMe
    lda #$0000 : jsr SelMoved       ; name, color, character
    ldx !SelMe
    rts

; ---- select after a continue in a 3P/4P game: the players who continued (credits
; >= 0 after the continue, $00:ABBC) choose; the others' boxes keep GAME OVER ----
Sel4EnterCont:
    jsl HudQueueFrame               ; 4-box HUD; contents again
    ldx.w #!P1_info : jsr Sel4Enter_redraw
    ldx.w #!P2_info : jsr Sel4Enter_redraw
    ldx.w #!P3_info : jsr Sel4Enter_redraw
    ldx.w #!P4_info : jsr Sel4Enter_redraw
    stz !SelHover                   ; turtles the original setup put in color (P1/P2)
    ldx #$0000
.player:
    stx !SelMe
    jsr SelJoined : bcc .next
    cpx #$0004 : bcs .p34
    lda.l SelInfo,x : tax
    lda $001A,x : asl : tax
    lda.l SelBit,x : ora !SelHover : sta !SelHover
    bra .next
.p34:
    lda.l SelInfo,x : tax
    lda $001A,x : sta !SelCand
    ldx !SelMe
    jsr Sel4Seat
.next:
    ldx !SelMe
    inx : inx
    cpx #$0008 : bcc .player
    jsr Sel4Frames
    jmp Sel4Graphics

; ---- portraits: in color while a cursor is on the turtle ----
Sel4Portraits:
    stz !SelMask
    ldx #$0000
-   jsr SelJoined : bcc +
    phx
    lda.l SelInfo,x : tax
    lda $001A,x : asl : tax
    lda.l SelBit,x : ora !SelMask : sta !SelMask
    plx
+   inx : inx
    cpx #$0008 : bcc -
    lda !SelMask : eor !SelHover : sta !SelChanged
    lda !SelMask : sta !SelHover
    ldx #$0000                      ; X = turtle * 2
.turtle:
    lda !SelChanged : lsr : sta !SelChanged : bcc .next
    txa : lsr : sta !SelCand        ; script D686[turtle (+4 in color) (+8 if $1FF0)]
    lda.l SelBit,x : and !SelHover : beq +
    lda !SelCand : clc : adc #$0004 : sta !SelCand
+   lda $1FF0 : beq +
    lda !SelCand : clc : adc #$0008 : sta !SelCand
+   phx
    lda !SelCand : asl : tay
    lda $D686,y : tay               ; DB = $01
    txa : asl #3 : clc : adc #$1F20 : tax   ; block $1F20 + $10 * turtle
    jsl Orig_PalScript
    plx
.next:
    inx : inx
    cpx #$0008 : bcc .turtle
    rts

; ---- cursors: position, frame, stacking ----
Sel4Cursors:
    stz !SelCount : stz !SelCount+2 : stz !SelCount+4 : stz !SelCount+6
    ldx #$0000
.player:
    jsr SelJoined : bcs +
    jmp .next
+   stx !SelMe
    lda.l SelInfo,x : tax
    lda $0010,x : sta !SelFrozen
    lda $001A,x : asl : tay         ; Y = turtle * 2
    lda !SelCount,y : sta !SelPos   ; place in this turtle's stack (0 = full cursor)
    inc : sta !SelCount,y
    ldx !SelMe
    lda.l SelCursor,x : tax
    lda $D6A6,y : sta $08,x         ; X of this turtle (DB = $01)
    lda !SelPos : beq +             ; 2nd-4th tag: beside the first
    dec : asl : sta !SelVar         ; slot * 2 (temporary)
    tya : sta !SelCand              ; turtle * 2
    asl : clc : adc !SelCand        ; turtle * 6: row of SelSlotX
    clc : adc !SelVar
    phx
    tax
    lda.l SelSlotX,x
    plx
    clc : adc $08,x : sta $08,x
+   lda.w #!CursorY : sta $0C,x
    lda !SelFrozen : bne +          ; frame variant: B every other 8 frames
    lda !SelTick : and #$0008 : beq +
    lda #$0020
    bra ++
+   lda #$0000
++  sta !SelVar
    ldx !SelMe
    lda !SelPos : bne .tag
    lda !SelVar : bne +
    lda.l SelFullA,x
    bra .set
+   lda.l SelFullB,x
    bra .set
.tag:
    txa : asl #5 : clc : adc.w #!FrTag : clc : adc !SelVar   ; player * $40 + variant
.set:
    pha
    lda.l SelCursor,x : tax
    pla : sta $00,x
    ldx !SelMe
.next:
    inx : inx
    cpx #$0008 : bcs +
    jmp .player
+   rts

; ---- confirmations ($04:9579 after the HUD driver; was LDA $1A90 / BNE $9595) ----
; Four-player select: done when every taking-part player has confirmed.
Sel4Confirm:
    lda !Sel4State : cmp #$0001 : beq .four
    lda $1A90 : beq +
    jml $049595
+   jml $04957E
.four:
    ldx #$0000
-   jsr SelJoined : bcc +
    phx
    lda.l SelInfo,x : tax
    lda $0010,x
    plx
    cmp #$0000 : beq .wait
+   inx : inx
    cpx #$0008 : bcc -
    jml $0495BA                     ; all confirmed
.wait:
    jml $04956B                     ; RTL

; ---- select over ($04:95BA, all confirmed or time-out; was LDY #$91CD / JSL $00A152) ----
Sel4Done:
    lda !Sel4State : cmp #$0001 : bne .orig
    ldx #$0000                      ; time-out: unconfirmed players take a free turtle
.player:
    jsr SelJoined : bcc .next
    stx !SelMe
    lda.l SelInfo,x : tax
    lda $0010,x : bne +
    lda #$0001 : sta $0010,x
    lda $001A,x
    ldx !SelMe
    jsr SelLocked : bcc ++
    lda #$0001 : jsr SelStep
++  lda #$0000 : jsr SelMoved
+   ldx !SelMe
.next:
    inx : inx
    cpx #$0008 : bcc .player
    jsr Sel4Portraits               ; show the final choices
    jsr Sel4Cursors
.orig:
    ldy #$91CD
    jsl $00A152
    jml $0495C1

; ---- end of the select screen ($04:95F2; was LDX #$05C0 / JSL $008BCD): cursors off ----
Sel4End:
    lda !Sel4State : and #$0001 : beq +     ; states 1 and 3
    ldx.w #!P3_compB : jsl Orig_ObjClear
    ldx.w #!P4_compB : jsl Orig_ObjClear
+   ldx.w #!P1_compB
    jsl Orig_ObjClear
    jml $0495F9

Select4End:
assert Select4End <= $20FFFF, "select4 code overflows bank $20"

; ---- hooks ----
org $049571 : jsl Sel4Frame         ; was JSL $04964E
org $049579                         ; was LDA $1A90 / BNE $9595
    jml Sel4Confirm
    nop
org $0495BA                         ; was LDY #$91CD / JSL $00A152
    jml Sel4Done
    nop : nop : nop
org $0495F2                         ; was LDX #$05C0 / JSL $008BCD
    jml Sel4End
    nop : nop : nop
