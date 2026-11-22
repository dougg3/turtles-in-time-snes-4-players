; Difficulty for three and four players: more enemies at once, more enemies in all,
; tougher bosses.
;
; The original scales a 2P game with a few "2P only" entries in each scene's enemy
; list ($A8) and nothing else, and 3P/4P games got exactly that. Here everything goes
; by the number of players in the game right now (!DifN: object pointers set, so a
; player waiting to continue or not yet joined doesn't count). Up to two players:
; the original game. Three / four players:
;   - the on-screen enemy limit ($19E8: 4 at stage start, 2-4 from list command
;     $17) is 1 / 2 higher;
;   - Foot soldiers and the other walk-in enemies of the list come in twice: every
;     second one / every one. The copy enters right behind the first, a little
;     further out and at another depth, so the two never overlap;
;   - hits on bosses take 2/3 / 1/2 of their health (the boss bar stays right, as
;     it shows health).
; Enemies still share the nine enemy slots of the object pool (11-19).

!DifN       = $7F2020           ; players in the game this frame (3P/4P games only)
!DifCapBase = $7F2022           ; the game's own enemy limit
!DifRem     = $7F2024           ; boss damage: remainder of the last division
!DifTmp     = $7F2026
!DifTmp2    = $7F2028
!DupPending = $7F202A           ; non-zero: the list entry at !DupPtr comes once more
!DupPtr     = $7F202C           ; $19C8 after that entry
!DupToggle  = $7F202E           ; three players: every second entry
!DupGun     = $7F2030           ; bit per enemy slot (11-19): a copy that stops further in
!DupBit     = $7F2032
!DupReplay  = $7F2034           ; non-zero: DupTick is spawning a queued copy
!DupTried   = $7F203C           ; DupTick: a spawn was tried this frame
!DupQMagic  = $7F2038           ; !DupQOk once the queue has been cleared
!DupQScene  = $7F203A           ; the scene ($82) the queue belongs to
!DupQFrame  = $7F203E           ; the mode's frame count ($78) at the last DupTick
!DupQ       = $7F2040           ; 8 copies to come, 6 bytes each: frames left (0 = free;
                                ; due from !DupQWait down, given up at 0), list entry, $19CA
!DupQOk     = $D4A7
!DupQWait   = $0258             ; (ten seconds)
!DupKindV   = $7F2036
!DupBeside  = $0100             ; kinds of copy, see DupKind
!DupFlip    = $0200

org $248200
assert WarpIn4End <= $248200, "warpin4 runs into difficulty4"

; ---- every frame of a 3P/4P game (UpdatePlayers4, HoverPlayers4) ----
Dif4Frame:
    lda #$0000
    ldx $9E : beq +
    inc
+   ldx $A0 : beq +
    inc
+   ldx.w !P3_ptr : beq +
    inc
+   ldx.w !P4_ptr : beq +
    inc
+   sta.l !DifN
    sec : sbc #$0002 : bcs +
    lda #$0000
+   sta.l !DifTmp
    lda.l !DifCapBase : and #$00FF
    clc : adc.l !DifTmp
    sta $19E8
    ; fall through

; The copies that come later (DupTypes with a number of frames) wait here, so the
; list goes on meanwhile and a group still comes in together, its copies after it.
; A copy that is due is spawned as the list would ($03:8E8F on its entry), one a
; frame, when the enemy limit and the pool allow; after !DupQWait frames of that it
; is given up. The queue is emptied when the scene changes, when the game leaves the
; modes that run the list or a frame passes without this routine; a copy from the
; elevator's lists (below $D100) only comes while the list is still the elevator's.
DupTick:
    lda.l !DupQFrame : inc : sta.l !DifTmp
    lda $78 : sta.l !DupQFrame      ; ($78: +1 a frame at $00:A555, 0 in a new mode)
    cmp.l !DifTmp : bne .clear      ; frames went by without this: e.g. all continued
    lda.l !DupQMagic : cmp #!DupQOk : bne .clear
    lda $82 : and #$00FF : cmp.l !DupQScene : beq .run
.clear:
    lda #!DupQOk : sta.l !DupQMagic
    lda $82 : and #$00FF : sta.l !DupQScene
    lda #$0000 : sta.l !DupReplay
    sta.l !DupGun
    ldx #$0000
-   lda #$0000 : sta.l !DupQ,x
    txa : clc : adc #$0006 : tax
    cpx #$0030 : bcc -
    rtl
.run:
    lda $70 : cmp #$000A : beq +    ; only in the modes that run the list (the stage
    cmp #$0016 : bcc .clear         ; $00:A72E, Scene 8 $00:A762, the end of Scene 4
    cmp #$0019 : bcs .clear         ; $00:A789): in any other, e.g. while a stage is
+   lda #$0000 : sta.l !DupTried    ; being cleared, the copies still to come are dropped
    ldx #$0000
.slot:
    lda.l !DupQ,x : beq .next
    cmp #!DupQWait+$0049 : bcc +    ; (the longest wait in DupTypes is 72)
    lda #$0001
+   dec : sta.l !DupQ,x : beq .next ; given up
    jsr DupGfx : bcc +              ; (every frame, due or not: none of the list's
    lda #$0000 : sta.l !DupQ,x      ; loads in between is missed) its graphics have
    bra .next                       ; made way for the next enemies'
+   lda.l !DupQ,x : cmp #!DupQWait : bcs .next      ; not due yet
    lda.l !DupTried : bne .next     ; one a frame
    lda.l !DupQ+2,x : cmp #$D100 : lda #$0000 : rol : sta.l !DifTmp
    lda $19C8 : cmp #$D100 : lda #$0000 : rol
    cmp.l !DifTmp : beq +
    lda #$0000 : sta.l !DupQ,x      ; the elevator's, and the list isn't any more (or
    bra .next                       ; the other way round)
+   lda $19DA : cmp $19E8 : bcs .next       ; the limit, as the list ($03:8C91)
    jsr DupSpawn
.next:
    txa : clc : adc #$0006 : tax
    cpx #$0030 : bcc .slot
    rtl

; DupTick: are the graphics of the queued copy X still there? The list loads an
; entry's five groups ($02:C789 by type -> five words; loaded: $14EA) before it
; spawns it, and first waits (state $19C6 = 1) until no enemy uses the ones they
; replace ($19D6, counted after the list each frame): a copy that is still to come
; doesn't make it wait. Carry clear: yes (they are loaded, or the list is waiting
; and will still be after this frame). Keeps X.
DupGfx:
    lda $19C6 : cmp #$0001 : bne +
    lda $19D6 : bne .yes            ; (none counted a frame ago: the list goes on to
+   phx                             ; load this very frame, before a copy would count)
    lda.l !DupQ+2,x : tax
    lda.l $020002,x : and #$00FF : asl : tax
    lda.l $02C789,x : tax
    ldy #$0000
-   lda.l $020000,x : beq +
    cmp $14EA,y : bne .no
+   inx : inx
    iny : iny
    cpy #$000A : bcc -
    plx
.yes:
    clc
    rts
.no:
    plx
    sec
    rts

; DupTick: the queued copy X (offset into !DupQ) now. Keeps X.
DupSpawn:
    lda #$0001 : sta.l !DupTried
    phx
    lda $19C8 : pha
    lda $19CA : pha
    lda.l !DupQ+4,x : sta $19CA
    lda.l !DupQ+2,x : sta $19C8
    lda #$0001 : sta.l !DupReplay
    phb
    pea $0202 : plb : plb           ; the list is read through the data bank
    jsl $038E8F                     ; (carry set: no room)
    plb
    lda #$0000 : sta.l !DupReplay
    pla : sta $19CA
    pla : sta $19C8
    plx
    bcs +                           ; again next frame
    lda #$0000 : sta.l !DupQ,x
+   rts

; A = frames: the list entry just spawned (X = its object; $19C8 is past it) comes
; once more after that many. Keeps X. (Queue full: it doesn't.)
DupQueue:
    sta.l !DifTmp
    phx
    ldx #$0000
-   lda.l !DupQ,x : beq .put
    txa : clc : adc #$0006 : tax
    cpx #$0030 : bcc -
    plx
    rts
.put:
    lda.l !DifTmp : clc : adc #!DupQWait : sta.l !DupQ,x
    lda $19C8 : sec : sbc #$0004 : sta.l !DupQ+2,x
    lda $19CA : sta.l !DupQ+4,x
    plx
    rts

; ---- $03:8486 (the elevator of Scene 4: the list is at its end; was LDA $19DA /
; BNE + / INC $190B: on to the next wave once no enemy is left) ---- not while
; copies of this wave are still to come
ElevNext:
    lda $19DA : bne .wait
    lda.l !PlayerMode : and #$00FF : cmp #$0003 : bcc .go
    lda.l !DupQMagic : cmp #!DupQOk : bne .go
    phx
    ldx #$0000
-   lda.l !DupQ,x : bne .busy
    txa : clc : adc #$0006 : tax
    cpx #$0030 : bcc -
    plx
.go:
    inc $190B
.wait:
    rtl
.busy:
    plx
    rtl

; ---- $03:8BDC (stage start; was LDA #$0004 / STA $19E8) ----
CapInit:
    lda #$0004
    sta $19E8
    sta.l !DifCapBase
    rtl

; ---- $03:8A2D (list command $17; was STA $19E8 / JMP $86D8) ----
CapCmd:
    sta $19E8
    sta.l !DifCapBase
    jml $0386D8

; ---- $03:8EC7 (list spawn; was JSL $028006 = init by type). X = the new object with
; position, type and variant set; $19C8 is already past its list entry ----
DupInit:
    lda.l !PlayerMode : and #$00FF : cmp #$0003 : bcs .four
    jml $028006
.four:
    jsr GunBit                      ; a new object in this slot: not a gunner's copy
    eor #$FFFF : and.l !DupGun : sta.l !DupGun
    lda.l !DupReplay : bne .copyinit        ; a queued copy (DupTick)
    lda.l !DupPending : beq .tofirst
    lda #$0000 : sta.l !DupPending
    lda $19C8 : cmp.l !DupPtr : beq .copyinit
.tofirst:
    jmp .first
.copyinit:
    jsr DupKind : sta.l !DupKindV
    ; the copy: another depth (mirrored in the scene's band, or the band's far edge
    ; when that is less than $18 away) and $18 further out
    phx
    lda.l !DupKindV : and #!DupFlip : beq .scene
    lda #$000B : bra .band          ; the hovering gunners keep to their own heights
.scene:
    lda $19C8 : cmp #$D100          ; the lists of the elevator ($02:CF3E...) come
    lda #$000A : bcc +              ; before the scenes': its own, narrower band
    lda $82 : and #$000F
+
.band:
    asl : asl : tax
    lda.l DupBand,x : sta.l !DifTmp
    lda.l DupBand+2,x : sta.l !DifTmp2
    plx
    lda.l !DupKindV : and #!DupBeside|!DupFlip : bne +
    jmp .init                       ; only later: the same entry once more, as it is
+   and #!DupFlip : beq +
    lda $32,x : eor #$0001 : sta $32,x      ; from the other side
    bra .mirror
+   lda $14,x : cmp #$01BA : bcc .mirror
    cmp #$01BE : bcs .mirror
    ; $1BA/$1BC, the Stone Warriors that walk in to a fixed spot and shoot from
    ; there. Their list entries come in pairs at mirrored depths, so a mirrored copy
    ; would stand on the other entry's spot: $18 deeper instead (the band's highest
    ; depth when that is nearer, $18 higher up when even that is under $0C away)
    lda $0C,x : clc : adc #$0018 : sta.l !DifTmp
    lda.l !DifTmp2 : cmp.l !DifTmp : bcs .gunx
    sta.l !DifTmp
    sec : sbc $0C,x : cmp #$000C : bcs .gunx
    lda $0C,x : sec : sbc #$0018 : sta.l !DifTmp
.gunx:
    lda.l !DifTmp : sta $0C,x
    ; they all walk in to the same X ($03:F615), whatever the list said: the copy
    ; goes on to a spot $28 further in (GunStop)
    jsr GunBit
    ora.l !DupGun : sta.l !DupGun
    bra .right
.mirror:
    lda.l !DifTmp : sec : sbc $0C,x : sta.l !DifTmp
    sec : sbc $0C,x : bpl +
    eor #$FFFF : inc
+   cmp #$0018 : bcs .set
    lda.l !DifTmp : cmp $0C,x : bcs .high   ; lower half: the band's highest depth
    clc : adc $0C,x                 ; upper half: its lowest (the sum - highest)
    sec : sbc.l !DifTmp2 : sta.l !DifTmp
    bra .set
.high:
    lda.l !DifTmp2 : sta.l !DifTmp
.set:
    lda.l !DifTmp : sta $0C,x
.right:
    lda $08,x : clc : adc #$0018 : sta $08,x
.init:
    ldy $19C8                      ; as at the original call
    jml $028006
.first:
    jsl $028006
    lda.l !DifN : cmp #$0003 : bcc .done
    jsr DupKind : beq .done
    sta.l !DupKindV
    lda $14,x : cmp #$0160 : bcc .walker
    lda $5C,x : and #$001C : beq .done      ; not an enemy the limit counts
.walker:
    lda.l !DifN : cmp #$0004 : bcs .copy
    lda.l !DupToggle : inc : and #$0001 : sta.l !DupToggle
    beq .done
.copy:
    lda.l !DupKindV : and #$00FF : beq .now
    sta.l !DifTmp2                  ; later: into the queue
    lda $14,x : cmp #$015E : bne +
    lda $32,x : and #$0010 : beq +  ; a Roadkill Rodney that rides in from the side
    lda #$0018 : sta.l !DifTmp2     ; (variant bit 4): follows sooner, in the same lane
+   lda.l !DifTmp2
    jsr DupQueue
    rtl
.now:
    lda $19C8 : sta.l !DupPtr
    sec : sbc #$0004 : sta $19C8    ; the list stays at this entry
    lda #$0001 : sta.l !DupPending
.done:
    rtl

; How the list enemy X (type +$14) comes a second time -> A (and Z): 0 not at all,
; else !DupBeside (another depth and $18 further out), !DupFlip (from the other
; side: variant bit 0 turned over; another depth as well), and in the low byte the
; number of frames it comes later. Keeps X and Y.
DupKind:
    lda $14,x
    cmp #$0160 : bcc .table         ; $160-$176 Foot soldiers
    cmp #$0178 : bcc .beside
    cmp #$0180 : bcc .table         ; $180-$18A Foot soldiers on boards
    cmp #$018C : bcc .beside
    cmp #$01B0 : bcc .table         ; $1B0-$1BC Stone Warriors, robots
    cmp #$01BE : bcs .table
.beside:
    lda #!DupBeside
    rts
.table:
    sta.l !DifTmp
    phx
    ldx #$0000
-   lda.l DupTypes,x : beq .found   ; (end: kind 0)
    cmp.l !DifTmp : beq .hit
    inx #4
    bra -
.hit:
    lda.l DupTypes+2,x
.found:
    sta.l !DifTmp
    plx
    lda.l !DifTmp
    rts

; type, kind. The Foot soldiers that come in their own way (through a door, over a
; fence...) go by the variant, not by the list's position: the same again, later.
; Roadkill Rodneys too (they keep to their own lanes). Mousers go by the list or
; follow a fixed path, by the variant: beside and later.
DupTypes:
    dw $0010, 40                    ; Foot soldier over the fence (orange)
    dw $0016, 40                    ; ... out of a door
    dw $001A, 40                    ; ... out of the doorway (Scene 1)
    dw $007A, 40                    ; ... dropping from a window
    dw $007C, 40                    ; ... over the fence (purple)
    dw $00CA, 40                    ; ... jumping aboard over the rail
    dw $00CC, 40, $00CE, 40, $00D0, 40, $00D2, 40   ; the elevator's
    dw $010C, 40, $010E, 40, $019A, 40
    dw $013C, !DupFlip              ; hovering robot gunner
    dw $0158, !DupBeside|30         ; Mouser
    dw $015E, 72                    ; Roadkill Rodney: out of a hole, when the first has left it
    dw 0

; A = the bit of !DupGun for the enemy slot X ($08D0-$0C50; anything lower gives
; slot 11's). Keeps X and Y.
GunBit:
    lda #$0001 : sta.l !DupBit
    txa
-   cmp #$08D0+$70 : bcc +
    sbc #$0070
    pha
    lda.l !DupBit : asl : sta.l !DupBit
    pla
    bra -
+   lda.l !DupBit
    rts

; ---- $03:F615 (Stone Warriors $1BA/$1BC walking in to their spot; was LDA $08,X /
; SEC / SBC #$0028 / CMP #$00B0: carry clear = there, X within $28-$D7) ----
GunStop:
    lda.l !PlayerMode : and #$00FF : cmp #$0003 : bcc .plain
    cpx #$08D0 : bcc .plain
    jsr GunBit
    and.l !DupGun : beq .plain
    ; the copy: $28 further in on the side it comes from. The other bound stays (a
    ; $1BA hit before its first shot walks in again, from wherever it is)
    lda $42,x : beq .toright
    lda $08,x : sec : sbc #$0028 : cmp #$0088   ; walking left: X within $28-$AF
    rtl
.toright:
    lda $08,x : sec : sbc #$0050 : cmp #$0088   ; walking right: X within $50-$D7
    rtl
.plain:
    lda $08,x : sec : sbc #$0028 : cmp #$00B0
    rtl

; per scene ($82): lowest + highest depth of its walk-in entries, highest depth
DupBand:
    dw $91+$D5, $D5
    dw $7E+$D5, $D5
    dw $76+$CD, $CD
    dw $87+$D1, $D1
    dw $80+$D1, $D1
    dw $86+$D1, $D1
    dw $80+$B1, $B1
    dw $20+$E0, $E0
    dw $85+$D2, $D2
    dw $80+$D0, $D0
    dw $9B+$B2, $B2                 ; (10) the elevator of Scene 4
    dw $A0+$BF, $BF                 ; (11) the hovering gunners of Scene 8
    dw $80+$D0, $D0                 ; (index is masked to 0-15)
    dw $80+$D0, $D0, $80+$D0, $D0, $80+$D0, $D0

; ---- the bosses' JSL $048572 (health +$4A minus damage +$56; carry = defeated) ----
BossDamage:
    lda.l !PlayerMode : and #$00FF : cmp #$0003 : bcs .four
.plain:
    jml $048572
.four:
    lda.l !DifN : cmp #$0003 : bcc .plain
    lda $56,x : pha
    jsr ScaleDamage
    sta $56,x
    jsl $048572
    sta.l !DifTmp
    pla : sta $56,x
    lda.l !DifTmp                   ; A, flags and carry as $048572 left them
    rtl

; ---- the Pizza Monsters of Scene 3 (type $142). Their controller (list type $046,
; $00:EB41) launches them one by one from the table at $01:A46F: +$36, depth,
; frames under water before the jump (they swim in from the left at 2 a frame, so
; this is where they come up), frames to the next. At most three are out ($19F2).

; $00:EE28 (was LDA $19F2 / CMP #$0003; BPL = no room): four with three players,
; five with four
PizzaLimit:
    lda.l !PlayerMode : and #$00FF : cmp #$0003 : bcc .plain
    lda.l !DifN : cmp #$0003 : bcc .plain
    lda $19F2 : dec : sec : sbc.l !DifN     ; $19F2 - (players + 1)
    rtl
.plain:
    lda $19F2 : cmp #$0003
    rtl

; $00:EE61 (the end of a launch; was STZ $3E,X / PLX / RTL; X = the new monster,
; the controller on the stack): one more with it (three players: with every
; second), at another depth and of the other kind: on the other side of the screen,
; jumping the other way
PizzaCopy:
    stz $3E,x
    lda.l !PlayerMode : and #$00FF : cmp #$0003 : bcc .out
    lda.l !DifN : cmp #$0003 : bcc .out
    cmp #$0004 : bcs .copy
    lda.l !DupToggle : inc : and #$0001 : sta.l !DupToggle
    bne .copy
.out:
    plx
    rtl
.copy:
    lda $19F2 : dec : cmp.l !DifN : bcs .out        ; players + 1 are out already
    lda $36,x : sta.l !DifTmp
    lda $0C,x : sta.l !DifTmp2
    lda $32,x : sta.l !DupBit
    jsl $048685 : bcs .done                 ; (X = the copy)
    lda #$0142
    jsl $028004
    inc $19F2
    lda.l !DifTmp : eor #$0010 : sta $36,x  ; (bit 4: it jumps to the left) the other way
    ; depth: mirrored in $82-$D2; $28 lower (or higher) when that is under $18 away
    lda #$0082+$00D2 : sec : sbc.l !DifTmp2 : sta $0C,x
    sec : sbc.l !DifTmp2 : bpl +
    eor #$FFFF : inc
+   cmp #$0018 : bcs .time
    lda.l !DifTmp2 : clc : adc #$0028
    cmp #$00D3 : bcc +
    sbc #$0050
+   sta $0C,x
.time:
    ; as the table's own two kinds: $20 under water and a jump to the right (it comes
    ; up on the left), or $70/$80 (+$36 $10/$30) and a jump to the left (on the right)
    lda.l !DupBit : cmp #$0050 : bcc .long
    lda #$0020 : bra .settime
.long:
    lda.l !DifTmp : and #$0020 : beq +
    lda #$0080 : bra .settime
+   lda #$0070
.settime:
    sta $32,x
    stz $3E,x
.done:
    plx
    rtl

; ---- $02:8308 (Shredder's tank, hit by a thrown Foot soldier; was LDA $4A,X / SEC /
; SBC #$000A / STA $4A,X) ----
TankDamage:
    lda.l !PlayerMode : and #$00FF : cmp #$0003 : bcc .plain
    lda.l !DifN : cmp #$0003 : bcc .plain
    lda #$000A
    jsr ScaleDamage
    sta.l !DifTmp
    lda $4A,x : sec : sbc.l !DifTmp : sta $4A,x
    rtl
.plain:
    lda $4A,x : sec : sbc #$000A : sta $4A,x
    rtl

; A = damage -> A = damage * 2/3 (three players) or 1/2 (four); the remainder goes
; into the next hit. Keeps X and Y.
ScaleDamage:
    sta.l !DifTmp
    lda.l !DifN : cmp #$0004 : bcs .half
    lda.l !DifRem : and #$0003
    clc : adc.l !DifTmp : adc.l !DifTmp
    sta.l !DifTmp
    lda #$0000 : sta.l !DifTmp2
-   lda.l !DifTmp : cmp #$0003 : bcc +
    sbc #$0003 : sta.l !DifTmp
    lda.l !DifTmp2 : inc : sta.l !DifTmp2
    bra -
+   sta.l !DifRem
    lda.l !DifTmp2
    rts
.half:
    lda.l !DifRem : and #$0001
    clc : adc.l !DifTmp
    lsr
    pha
    lda #$0000 : rol : sta.l !DifRem
    pla
    rts

Difficulty4End:
assert Difficulty4End <= $24FFFF, "difficulty4 code overflows bank $24"

; ---- hooks ----
org $038BDC
    jsl CapInit
    nop #2
assert pc() == $038BE2
org $038A2D
    jml CapCmd
    nop #2
assert pc() == $038A33
org $038EC7 : jsl DupInit
org $038486
    jsl ElevNext
    nop #4
assert pc() == $03848E
org $03F615
    jsl GunStop
    nop #5
assert pc() == $03F61E
org $00EE28
    jsl PizzaLimit
    nop #2
assert pc() == $00EE2E
org $00EE61 : jml PizzaCopy             ; (4 bytes)
org $028308
    jsl TankDamage
    nop #4
assert pc() == $028310
; Baxter, Krang (both), Slash, Metalhead, Tokka, Rahzar, Rat King, Bebop,
; Rocksteady, Super Shredder; Leatherhead in bank $02
org $058711 : jsl BossDamage
org $058791 : jsl BossDamage
org $05924F : jsl BossDamage
org $059E83 : jsl BossDamage
org $059F29 : jsl BossDamage
org $05A747 : jsl BossDamage
org $05B5B1 : jsl BossDamage
org $05B6C6 : jsl BossDamage
org $05C828 : jsl BossDamage
org $05C8C9 : jsl BossDamage
org $05D12D : jsl BossDamage
org $05D1CA : jsl BossDamage
org $05D8A7 : jsl BossDamage
org $05E372 : jsl BossDamage
org $05E4F8 : jsl BossDamage
org $05EC6A : jsl BossDamage
org $05F5B6 : jsl BossDamage
org $029201 : jsl BossDamage

; ---- fixes for a full enemy pool (it fills up far more often now) ----
; $03:A91C (a Foot soldier throws a harpoon, Scene 6): PHA / PHX / JSL $048685 / TXY /
; PLX / BCS -> RTL. With no free slot the original returned without pulling A: a
; return into nowhere. Here the last three instructions, with the PLA.
org $24A000
assert Difficulty4End <= $24A000, "difficulty4 runs into its pool fixes"
HarpoonAlloc:
    txy
    plx
    bcs .full
    jml $03A926
.full:
    pla
    rtl

; $03:8E8F (list spawn; was JSL $048685). Several boss and set-piece set-ups take
; slots without testing for failure ($02:96A9 the boss bar, $03:84D1, $03:9983,
; $05:8A9D, $05:93AD, $05:A285, $05:DDDC, $05:E2B6) and write into another object's
; companion when the pool is full. With three or four players the list therefore
; spawns only while three enemy slots are free, so two stay free for such things;
; a list entry that has to wait is tried again every frame, as with a full pool.
ListAlloc:
    lda.l !PlayerMode : and #$00FF : cmp #$0003 : bcs .four
.go:
    jml $048685
.four:
    lda.l !DifN : cmp #$0003 : bcc .go
    ldx #$08D0                      ; free = type and both companions' types 0,
    ldy #$0000                      ; as the allocator tests it
-   lda $14,x : bne +
    lda $0404,x : bne +
    lda $07F4,x : bne +
    iny
+   txa : clc : adc #$0070 : tax
    cpx #$0CC0 : bcc -
    cpy #$0003 : bcs .go
.full:
    ldx #$0CC0                      ; as the allocator when full
    sec
    rtl
PoolFixesEnd:
assert PoolFixesEnd <= $24FFFF, "pool fixes overflow bank $24"

org $03A922 : jml HarpoonAlloc      ; TXY / PLX / BCS $A94F (4 bytes)
org $038E8F : jsl ListAlloc
