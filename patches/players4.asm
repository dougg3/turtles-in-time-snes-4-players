; Players 3 and 4: setup, spawn, per-frame update.
;
; Everything here is inactive unless !PlayerMode >= 3, so 1P/2P games behave
; as before (scripts/regress.sh). RAM addresses: ram.asm. For the proof of
; concept the test harness sets !PlayerMode at character select; menus come later (M7).

; Original routines used below
Orig_PlayerUpdate   = $00AD54
Orig_PlayerTick     = $00ADF9   ; per-player update entry, Y = index*2 (stores $1864)
Orig_PlayerB98E     = $00B98E
Orig_PlayerC8CE     = $00C8CE
Orig_PlayerB690     = $00B690
Orig_SpawnPlayers   = $04AF1A
Orig_InitHealth     = $00AF72   ; +$4A = start health for the character in +$14
Orig_InfoSetHud     = $04AF75   ; info +$22 = A, +$2C = 7
Orig_InfoHud2       = $04AF7F
Orig_InfoInit       = $0497AC   ; info +$20 lives, +$22, +$1C, +$2E

org $00FC00
assert PlayerHelpersEnd <= $00FC00, "player helpers run into players4 code"

; ---- per-frame update: original P1/P2, then P3/P4 (same calls as $00:AD7E-$ADA4) ----
UpdatePlayers4:
    jsl Orig_PlayerUpdate
    lda !PlayerMode : and #$00FF : cmp #$0003 : bcc .done
    ldx !P3_ptr : beq .p4
    ldy #$0004 : jsr .tick
.p4:
    ldx !P4_ptr : beq .done
    ldy #$0006 : jsr .tick
.done:
    rtl
.tick:                      ; X = object, Y = index*2
    stx $FC
    jsl Orig_PlayerTick
    ldx $FC
    jsl Orig_PlayerB98E
    lda $187E : bne +
    jsl Orig_PlayerC8CE
    lda $000C,x : sta $12,x
    lda $30,x
    jsl Orig_PlayerB690
+   rts

; ---- spawn at stage start: original P1/P2, then P3/P4 (same as $04:AF1A-$AF6A) ----
SpawnPlayers4:
    jsl HudQueueFrame       ; 3P/4P: compact HUD frame first (hud4.asm), contents follow
    jsl Orig_SpawnPlayers
    lda !PlayerMode : and #$00FF : cmp #$0003 : bcc .done
    ; first time in 3P/4P: assign pointers and initialize info blocks (as $04:977F)
    lda !P3_ptr : bne +
    lda.w #!P3_slot : sta !P3_ptr
    ldx.w #!P3_info : jsl Orig_InfoInit
    jsr .joined
+   lda !PlayerMode : and #$00FF : cmp #$0004 : bcc +
    lda !P4_ptr : bne +
    lda.w #!P4_slot : sta !P4_ptr
    ldx.w #!P4_info : jsl Orig_InfoInit
    jsr .joined
+   ldx !P3_ptr : beq +
    lda.w !P3_char : ldy.w #!P3_info : jsr .spawn
+   ldx !P4_ptr : beq .done
    lda.w !P4_char : ldy.w #!P4_info : jsr .spawn
.done:
    rtl
.joined:                    ; X = info block: values character select leaves for P1/P2
    lda #$0004 : sta $000E,x    ; ($1A8E/$1A90 for P1)
    lda #$0001 : sta $0010,x
    rts
.spawn:                     ; X = object, A = character, Y = info block
    phy
    sta $14,x
    pha : lsr : dec : sta $001A,y : pla ; info +$1A = HUD name index (Leo 0 ... Raph 3)
    jsl Orig_InitHealth
    stz $0016,x
    stz $0000,x
    plx                     ; X = info block (A = start health from Orig_InitHealth)
    phx
    jsl Orig_InfoSetHud
    plx
    lda $002C,x : ora #$0002 : sta $002C,x
    jsl Orig_InfoHud2
    rts

; ---- stage-intro placement ($04:EF39): place every present player ----
; Original: LDX $9E / BEQ / JSL $04EF45, then falls into $04:EF45 with X=[$A0].
; $04:EF45 = JSL $00:DEB1 (start position) / state $16 = $3A / RTL.
Orig_PlacePlayer = $04EF45
PlaceAllPlayers:
    ldx $9E : beq +
    jsl Orig_PlacePlayer
+   ldx $A0 : beq +
    jsl Orig_PlacePlayer
+   lda !PlayerMode : and #$00FF : cmp #$0003 : bcc .done
    ldx !P3_ptr : beq +
    jsl Orig_PlacePlayer
+   ldx !P4_ptr : beq .done
    jsl Orig_PlacePlayer
.done:
    rtl
; ---- enemy target selection ($04:8503, called from 77 places) ----
; 1P/2P: original code (first 4 bytes replayed here). 3P/4P: same rules over all
; living players (pointer set and health +$4A non-zero): random when they are
; within $50 px of each other (bit 0 of $18C0^$18C2 in the original; modulo the
; count here), otherwise the nearest in X to the enemy (X = enemy object).
; Returns Y = target, carry clear; carry set if nobody is targetable.
Orig_Target_P1Absent = $04856B
Orig_Target_Cont     = $048507
SelectTarget:
    lda !PlayerMode : and #$00FF : cmp #$0003 : bcs .four
    lda $9E : bne +                 ; original: LDA $9E / BEQ $856B
    jml Orig_Target_P1Absent
+   jml Orig_Target_Cont
.four:
    stz !Tgt_count
    lda #$FFFF : sta !Tgt_min
    stz !Tgt_max
    ldy $9E : jsr .consider
    ldy $A0 : jsr .consider
    ldy !P3_ptr : jsr .consider
    ldy !P4_ptr : jsr .consider
    lda !Tgt_count : bne +
    sec                             ; nobody targetable
    rtl
+   cmp #$0002 : bcs +
    ldy !Tgt_list : clc : rtl       ; exactly one
+   lda !Tgt_max : sec : sbc !Tgt_min
    cmp #$0050 : bcs .nearest
    lda $18C0 : eor $18C2           ; random among candidates
    and #$0003                      ; 0-3, then at most one subtraction (count >= 2)
-   cmp !Tgt_count : bcc +
    sec : sbc !Tgt_count : bra -
+   asl : tay
    lda !Tgt_list,y : tay
    clc
    rtl
.nearest:
    lda #$FFFF : sta !Tgt_best
    ldy #$0000
-   phy
    lda !Tgt_list,y : tay
    lda $0008,y : sec : sbc $08,x
    bpl + : eor #$FFFF : inc
+   ply
    cmp !Tgt_best : bcs +
    sta !Tgt_best
    lda !Tgt_list,y : sta !Tgt_min   ; reuse as "best pointer"
+   iny : iny
    tya : lsr : cmp !Tgt_count : bcc -
    ldy !Tgt_min
    clc
    rtl
.consider:                          ; Y = player pointer (0 = absent)
    cpy #$0000 : beq ++
    lda $004A,y : beq ++            ; health 0: not targetable
    lda !Tgt_count : asl : phx : tax
    tya : sta !Tgt_list,x
    plx
    inc !Tgt_count
    lda $0008,y
    cmp !Tgt_min : bcs +
    sta !Tgt_min
+   cmp !Tgt_max : bcc ++
    sta !Tgt_max
++  rts
; ---- deaths / game over ----
; $00:CED5: "is the other player out?" -> "are all other players out?"
; Original: LDA $1864 / EOR #2 / TAY / LDX $9CF7,Y / LDA $000E,X / BMI $CEFE / RTL
; Returns carry set if every other player in the game has info +$0E < 0.
OthersAllOut:
    ldx #$0000                      ; X = candidate index*2
.loop:
    cpx $1864 : beq .next           ; skip the current player
    cpx #$0004 : bcc .check         ; P1/P2 are always considered (as the original)
    lda !PlayerMode : and #$00FF : cmp #$0003 : bcc .next
    lda.l PlayerPtrTable-4,x : tay
    lda $0000,y : beq .next         ; P3/P4 pointer not set
.check:
    lda.l PlayerInfoBlock,x : tay
    lda $000E,y : bpl .notout       ; >= 0: still in the game
.next:
    inx : inx
    cpx #$0008 : bcc .loop
    sec                             ; everyone else is out
    rtl
.notout:
    clc
    rtl
PlayerPtrTable:
    dw !P3_ptr, !P4_ptr

; $00:CF18: game over only if P2 (and P3/P4 in 3P/4P) are out as well.
; Original: LDA $1ACE / BEQ $CF1F / BPL $CF25. Returns carry clear if any of
; them has +$0E > 0 (game continues).
OthersInPlay:
    lda $1ACE : beq + : bpl .yes
+   lda !PlayerMode : and #$00FF : cmp #$0003 : bcc .no
    lda !P3_ptr : beq +
    lda.w !P3_info+$0E : beq + : bpl .yes
+   lda !P4_ptr : beq .no
    lda.w !P4_info+$0E : beq .no : bpl .yes
.no:
    sec
    rtl
.yes:
    clc
    rtl
Players4End:
assert Players4End <= $00FFB0, "players4 code overflows bank $00 padding"

; ---- hooks ----
org $04AF0F : jsl SpawnPlayers4             ; was JSL $04AF1A
org $02931E : jsl SpawnPlayers4             ; was JSL $04AF1A
org $04EF39                                 ; was LDX $9E / BEQ / JSL $04EF45 / (P2 falls through)
    jsl PlaceAllPlayers
    rtl

; every caller of the player update ($00:AD54) now calls the 4-player wrapper
org $00A734 : jsl UpdatePlayers4
org $00A79B : jsl UpdatePlayers4
org $00A7BB : jsl UpdatePlayers4
org $00A803 : jsl UpdatePlayers4
org $00A834 : jsl UpdatePlayers4
org $029BF8 : jsl UpdatePlayers4
org $049916 : jsl UpdatePlayers4
org $04993F : jsl UpdatePlayers4
org $049A71 : jsl UpdatePlayers4
org $049AAC : jsl UpdatePlayers4
org $049ABC : jsl UpdatePlayers4
org $049B60 : jsl UpdatePlayers4
org $049B81 : jsl UpdatePlayers4
org $049B9B : jsl UpdatePlayers4
org $049CB5 : jsl UpdatePlayers4
org $049CC6 : jsl UpdatePlayers4
org $04A17D : jsl UpdatePlayers4
org $04A1AF : jsl UpdatePlayers4
org $04A215 : jsl UpdatePlayers4
org $04EF5B : jsl UpdatePlayers4

; ---- enemy attack vs players ($03:81F2, called from 98 places): also test P3/P4 ----
; Original: STZ $06 / LDY #$0400 / JSR $8207 / LDY #$0470 / JSR $8207 / LSR $06 / RTL.
; $03:8207 is a bank-local subroutine (box test, applies the hit, sets $06), so the
; extension lives in bank $03 padding ($03:FF4E, 178 bytes of $FF).
Orig_HitTest_8207 = $038207
org $038204
    jmp EnemyHitsP3P4           ; was LSR $06 / RTL
org $03FF50
EnemyHitsP3P4:
    lda !PlayerMode : and #$00FF : cmp #$0003 : bcc .done
    ldy !P3_ptr : beq +
    jsr Orig_HitTest_8207
+   ldy !P4_ptr : beq .done
    jsr Orig_HitTest_8207
.done:
    lsr $06                     ; carry = some player was hit (as the original)
    rtl
EnemyHitsEnd:
assert EnemyHitsEnd <= $03FFF0, "bank 03 extension overflows padding"

org $048503 : jml SelectTarget              ; was LDA $9E / BEQ $856B

; ---- camera ($04:EA49-ED47): leader/trailer over all players ----
; Every two-player camera block reads P1's X ($0408) and P2's X ($0478) and
; branches on which is ahead (the branches differ by 1 px in places, so 2P
; behavior depends on which player leads). All those reads now use CamA/CamB:
;   1P/2P: CamA = P1.X, CamB = P2.X  (identical to the original)
;   3P/4P: CamA = max X, CamB = min X over present players (always "A ahead")
; The first read of each block becomes JSR CamCalcY/CamCalcA (same 3 bytes),
; which computes CamA/CamB and returns the value the original instruction loaded.
org $04FF14
CamCalcY:                   ; replaces LDY $0478
    jsr CamCalc
    ldy !CamB
    rts
CamCalcA:                   ; replaces LDA $0408
    jsr CamCalc
    lda !CamA
    rts
CamCalc:
    lda $0408 : sta !CamA
    lda $0478 : sta !CamB
    lda !PlayerMode : and #$00FF : cmp #$0003 : bcc .done
    lda !CamB : cmp !CamA : bcc +   ; order the two so CamA >= CamB
    pha : lda !CamA : sta !CamB : pla : sta !CamA
+   ldy !P3_ptr : jsr .take
    ldy !P4_ptr : jsr .take
.done:
    rts
.take:                      ; widen [CamB, CamA] with player Y's X (Y = 0: absent)
    cpy #$0000 : beq +
    lda $0008,y
    cmp !CamA : bcc ++
    sta !CamA
++  cmp !CamB : bcs +
    sta !CamB
+   rts
CameraEnd:
assert CameraEnd <= $04FFFF, "camera helper overflows bank $04"

org $04EA49 : jsr CamCalcY
org $04EAF5 : jsr CamCalcY
org $04EBE4 : jsr CamCalcY
org $04ECA9 : jsr CamCalcA
org $04ECFD : jsr CamCalcY
org $04ED3E : jsr CamCalcY
; remaining reads: P1 X -> CamA, P2 X -> CamB (operands only)
org $04EA56+1 : dw !CamA
org $04EA63+1 : dw !CamB
org $04EAF8+1 : dw !CamA
org $04EAFB+1 : dw !CamB
org $04EBE7+1 : dw !CamA
org $04EBEA+1 : dw !CamB
org $04EBEF+1 : dw !CamA
org $04EBF2+1 : dw !CamB
org $04ECAC+1 : dw !CamB
org $04ECB1+1 : dw !CamB
org $04ED00+1 : dw !CamA
org $04ED03+1 : dw !CamB
org $04ED41+1 : dw !CamA
org $04ED44+1 : dw !CamB

Orig_CEFE = $00CEFE
Orig_CF25 = $00CF25
org $00CED5                         ; other player out? -> all other players out?
    jsl OthersAllOut
    bcs Orig_CEFE
    rtl
org $00CF18                         ; LDA $1ACE / BEQ / BPL $CF25 (7 bytes)
    jsl OthersInPlay
    bcc Orig_CF25
    nop

org $00F920                         ; free bank-0 gap (players4 main area is full)
assert JoypadEnd <= $00F920, "input code runs into PlaceP2P34"
; ---- other stage-intro placements ($04:F34E): place P2, then P3/P4 ----
; Replaces at $04:F356: LDX $A0 / BEQ $F35E / JSL $00DEB1 (8 bytes)
Orig_StartPos = $00DEB1
PlaceP2P34:
    ldx $A0 : beq +
    jsl Orig_StartPos
+   lda !PlayerMode : and #$00FF : cmp #$0003 : bcc .done
    ldx !P3_ptr : beq +
    jsl Orig_StartPos
+   ldx !P4_ptr : beq .done
    jsl Orig_StartPos
.done:
    rtl
PlaceP2P34End:
assert PlaceP2P34End <= $00FA00, "PlaceP2P34 overflows its gap"
org $04F356
    jsl PlaceP2P34
    nop : nop : nop : nop

; ---- vehicle intro ($04:EFB7): players arrive on boards (companion B, type 1) ----
; P1: place, JSR $EFFA (copy position), board $05C0 data $E7C6 (JSL $04:EFE0);
; then INC $1782; a later step does P2 ($06A0, $E7D8). P3/P4 are placed with P1's
; step and get boards in their companion-B slots (proof of concept: P1/P2 data).
org $04FF80
assert CameraEnd <= $04FF80, "bank 04 helpers overlap"
VehicleIntroP34:                    ; was INC $1782 (JSR, same 3 bytes)
    inc $1782
    lda !PlayerMode : and #$00FF : cmp #$0003 : bcc .done
    ldx !P3_ptr : beq +
    jsl Orig_StartPos
    jsr $EFFA
    ldx.w #!P3_compB : ldy #$E7C6
    jsl $04EFE0
+   ldx !P4_ptr : beq .done
    jsl Orig_StartPos
    jsr $EFFA
    ldx.w #!P4_compB : ldy #$E7D8
    jsl $04EFE0
.done:
    rts
VehicleIntroEnd:
assert VehicleIntroEnd <= $04FFFF, "bank 04 padding overflow"
org $04EFCC : jsr VehicleIntroP34
