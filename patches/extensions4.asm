; P3/P4 graphics and colors in the extension sprite memory.
;
; On a SNES the turtles' animation frames stream into fixed per-player sprite VRAM
; (P1 $6000-$62FF = tiles $000-$02F, palette 0; P2 $6300-$65FF = tiles $030-$05F,
; palette 1), and P3/P4 shared P1/P2's (wrong colors, clashing frames).
; With the extensions in 3P/4P play:
;   - P3/P4 frame uploads go to the extra tile memory instead: P3 to extra tiles
;     0-47, P4 to 48-95, i.e. the same tile numbers P1/P2 use (port address =
;     (VRAM word - $6000) * 2). Two ordinary VRAM-queue entries per upload: a 2-byte
;     DMA to $21C0/$21C1 (port address), then the data to $21C2.
;   - Their OAM entries get the extended attribute bits: tile page if the tile is in
;     their region, palette bank if the palette is their own (0 for P3, 1 for P4),
;     so shared tiles and other palettes (flashes) keep working.
;   - When OAM is full, the builder carries on into the extended entries 128-255
;     (shadow !PPExtLow/!PPExtHigh, uploaded to the port) instead of dropping the
;     remaining objects; they are drawn behind entries 0-127, as later entries are.
;   - Extra palettes 8/9 = P1's/P2's current palette 0/1 with the colors where the
;     turtles differ replaced by P3's/P4's turtle (ROM $09:92F9), faded by the same
;     amount as the game's palettes.
; 1P/2P, other modes, or no extensions: nothing changes (control register 0).

!PPAttr     = $15A0             ; 64 bytes extended attributes (low WRAM: written while the
                                ; builder runs with DB = $08)
!PPPal      = $7E7F40           ; 64 bytes palettes 8/9
!PPPalCache = $7E7F80           ; 64 bytes: the game's palettes 0/1 they were made from
!PPLo       = $1CE2             ; marking: first tile of the owner's region
!PPPalBits  = $1CE4             ; marking: owner's palette in attribute bits 9-11
!PPPalKey   = $1CE6             ; palettes made for: $D0, $D2, P3/P4 turtles (6 bytes)
!PPPalOK    = $1CEC
!PPBank     = $1CEE             ; PPAdd: bank of the source
!PPListN    = $1CF0             ; bytes used in !PPList
!PPList     = $7E7F00           ; uploads for the next NMI: source (3), port address
!PPListMax  = 9*7               ; (2), bytes (2); 9 entries
!PPCarry    = $1CF2             ; IsPlayerSlotFar: result of the player test             ; palettes 8/9 in the PPU are current for the key
!PPActive   = $1CC0             ; this frame: P3/P4 use the extensions
!PPStart    = $1CC2             ; first OAM entry of the P3/P4 object being drawn
!PPOwner    = $1CC4             ; its slot
!PPRet      = $1CC6             ; 3 bytes: where the object's draw routine returns to
!PPK        = $1CCA             ; fade amount
!PPTmp      = $1CCC
!PPI        = $1CCE
!PPOff      = $1CD0             ; palettes: byte offset of P3 (0) / P4 ($20)
!PPBase     = $1CD2             ; ROM record offset of the base turtle
!PPOwn      = $1CD4             ; ROM record offset of P3's/P4's turtle
!PPBufA     = $1CD6             ; the game's buffer palette 0/1 (bank $7E)
!PPEnd      = $1CD8             ; OAM entry after the P3/P4 object
!PPSrc      = $1CDA
!PPExt      = $1CDC             ; this frame's builder went past entry 127
!PPExtUsed  = $1CDE             ; extended entries in use (shown) after the last frame
!PPExtInit  = $1CE0             ; $5A5A once the extended shadow has been hidden
!PPExtLow   = $7E7C00           ; extended OAM shadow: 128 entries x 4 bytes
!PPExtHigh  = $15E0             ; its high table (32 bytes, low WRAM: the builder
                                ; stores it with STA ($02), DB = $08, and detects
                                ; "full" when the low byte of $02 wraps)

; extra scanlines per frame in 3P/4P play ($21C5/$21C6). Without them the
; frame logic (run in the NMI) sometimes spills into the next picture's top lines
; and the HUD shows half-updated settings.
!PPExtraCpu     = 192           ; before NMI: CPU time (4P lag <= 2P lag in all scenes)
!PPExtraVblank  = 16            ; after NMI: vblank (DMA) time

TurtlePalettes = $0992F9        ; 32 bytes per turtle: 4-byte header, colors 2-14;
                                ; second set at +$A0 when $1FF0 is set

org $20BA00
assert Slots4End <= $20BA00, "slots4 code runs into extensions4"

; carry set if the extension ID reads "S+"
PPPresent:
    php
    sep #$20
    lda.l $0021CE : cmp #'S' : bne .no
    lda.l $0021CF : cmp #'+' : bne .no
    plp
    sec
    rtl
.no:
    plp
    clc
    rtl

; ---- every frame, OAM builder start ($00:916C; was LDA #$03E0 / STA $02) ----
PPFrame:                            ; (A 16-bit)
    lda.l !PlayerMode : and #$00FF : cmp #$0003 : bcs .full
    lda.l !PPActive : ora.l !PPExt : ora.l !PPExtUsed : bne .full
    lda #$03E0 : sta $02            ; 1P/2P: as the original, nothing else
    rtl
.full:
    php
    rep #$30
    phx : phy
    lda.l !PPExt : beq +            ; last frame ended full in the extended OAM
    lda #$0080 : sta.l !PPExtUsed
    lda #$0000 : sta.l !PPExt
+
    lda #$0000 : sta.l !PPActive
    lda.l !PlayerMode : and #$00FF : cmp #$0003 : bcc .off
    lda.l $000070 : and #$001F : tax
    lda.l LiveModes,x : and #$00FF : beq .off
    jsl PPPresent : bcc .off
    lda #$0001 : sta.l !PPActive
    lda.l !PPExtInit : cmp #$5A5A : beq +
    jsr PPExtClear
+
    sep #$20
    lda #$03 : sta.l $0021C4        ; extended sprites, raised per-line limits
    lda.b #!PPExtraCpu : sta.l $0021C5  ; extra CPU time and vblank: four
    lda.b #!PPExtraVblank : sta.l $0021C6   ; players and more sprites need both
    rep #$20
    lda #$0000                      ; attributes: none yet (set while drawing)
    ldx #$003E
-   sta.l $7E0000+!PPAttr,x
    dex : dex : bpl -
    jsr PPPalCheck : bcc +          ; palettes 8/9 only when their sources changed
    jsr PPPalettes
    lda.w #!PPPal : ldy #$4400 : ldx #$0040 : jsr PPQueue
+   lda.w #!PPAttr : ldy #$4300 : ldx #$0040 : jsr PPQueue
    bra .done
.off:
    lda #$0000 : sta.l !PPPalOK     ; make palettes 8/9 again when switched on
    sep #$20
    lda #$00 : sta.l $0021C4        ; (on a SNES: unused B-bus addresses)
    sta.l $0021C5 : sta.l $0021C6
    rep #$20
.done:
    ply : plx
    plp
    lda #$03E0 : sta $02
    rtl

; carry set if palettes 8/9 must be made (and uploaded): first frame, other
; characters/turtles, or the game's palettes 0/1 changed (fades, effects). Updates
; the key and the cache.
PPPalCheck:
    lda.l !PPPalOK : beq .changed
    lda $D0 : cmp.l !PPPalKey : bne .changed
    lda $D2 : eor.w $1FF0 : cmp.l !PPPalKey+2 : bne .changed
    lda.w !P3_info+$1A : xba : ora.w !P4_info+$1A : cmp.l !PPPalKey+4 : bne .changed
    lda $42 : clc : adc #$0100 : sta.l !PPBufA
    ldy #$003E
-   tya : clc : adc.l !PPBufA : tax
    lda.l $7E0000,x
    tyx
    cmp.l !PPPalCache,x : bne .changed
    dey : dey : bpl -
    clc
    rts
.changed:
    lda $D0 : sta.l !PPPalKey
    lda $D2 : eor.w $1FF0 : sta.l !PPPalKey+2
    lda.w !P3_info+$1A : xba : ora.w !P4_info+$1A : sta.l !PPPalKey+4
    lda $42 : clc : adc #$0100 : sta.l !PPBufA
    ldy #$003E
-   tya : clc : adc.l !PPBufA : tax
    lda.l $7E0000,x
    tyx
    sta.l !PPPalCache,x
    dey : dey : bpl -
    lda #$0001 : sta.l !PPPalOK
    sec
    rts

; extended shadow: all 128 entries hidden, high table 0
PPExtClear:
    ldx #$01FC
-   lda #$F000 : sta.l !PPExtLow,x    ; X 0, Y $F0 (hidden)
    lda #$0000 : sta.l !PPExtLow+2,x
    dex #4 : bpl -
    ldx #$001E
-   sta.l !PPExtHigh,x
    dex : dex : bpl -
    sta.l !PPExtUsed
    lda #$5A5A : sta.l !PPExtInit
    jmp PPQueueExt                  ; the PPU's copy too (power-on contents)

; upload the extended OAM shadow in the next NMI (only in frames that use or stop
; using it: 544 bytes of vblank DMA)
PPQueueExt:
    lda.w #!PPExtLow : ldy #$4000 : ldx #$0200 : jsr PPQueue
    lda.w #!PPExtHigh : ldy #$4200 : ldx #$0020
    ; fall through

; A = source (bank $7E), Y = port address, X = bytes: two VRAM-queue entries
; ($00:8CCB runs them in the next NMI with DMA channel 0)
PPQueue:
    pha
    lda #$007E : sta.l !PPBank
    pla
    ; fall through

; A = source, !PPBank = its bank, Y = port address, X = bytes: upload in the next
; NMI. Normally into !PPList, written to the port after the HUD's vblank work
; (PPFlush: port writes need no vblank); in scenes whose HDMA may use channel 0
; ($1ED2 < 2), as two entries in the game's VRAM queue (run in vblank).
PPAdd:
    sta.l !PPTmp
    lda.l $001ED2 : and #$00FF : cmp #$0002 : bcc .queue
    lda.l !PPListN : cmp.w #!PPListMax : bcs .queue
    phx
    tax
    lda.l !PPTmp : sta.l !PPList,x
    lda.l !PPBank : sta.l !PPList+2,x
    tya : sta.l !PPList+3,x
    pla : sta.l !PPList+5,x
    txa : clc : adc #$0007 : sta.l !PPListN
    rts
.queue:
    phx
    lda $4A : tax                   ; small-data area: the port address
    tya : sta.l $7E0000,x
    txa : sta.l !PPI
    clc : adc #$0002 : sta $4A
    ldx $48
    lda #$0080 : sta.l $7E0000,x    ; VMAIN (as the game's entries)
    lda #$C001 : sta.l $7E0002,x    ; mode 1 to $21C0/$21C1
    lda #$0000 : sta.l $7E0004,x
    lda.l !PPI : sta.l $7E0006,x
    lda #$007E : sta.l $7E0008,x
    lda #$0002 : sta.l $7E0009,x
    lda #$0080 : sta.l $7E000B,x
    lda #$C200 : sta.l $7E000D,x    ; mode 0 to $21C2
    lda #$0000 : sta.l $7E000F,x
    lda.l !PPTmp : sta.l $7E0011,x
    lda.l !PPBank : sta.l $7E0013,x
    pla : sta.l $7E0014,x
    txa : clc : adc #$0016 : sta $48
    rts

; ---- NMI, end of the HUD's 3P/4P work (HudNmi in hud4.asm jumps here; 1P/2P never
; get here): write !PPList to the port with DMA channel 0 (free: HDMA uses channels
; >= 1 when entries are listed, see PPAdd) ----
PPFlush:
    php
    rep #$30
    pha : phx
    lda.l !PPListN : beq .done
    sep #$20
    lda #$00 : sta.l $004300        ; mode 0: one register, A-bus increment
    lda #$C2 : sta.l $004301        ; $21C2
    rep #$20
    ldx #$0000
.entry:
    lda.l !PPList+3,x : sta.l $0021C0   ; port address ($21C0, $21C1)
    lda.l !PPList,x : sta.l $004302
    lda.l !PPList+1,x : sta.l $004303   ; (bank byte from the next word)
    lda.l !PPList+5,x : sta.l $004305
    sep #$20
    lda #$01 : sta.l $00420B
    rep #$20
    txa : clc : adc #$0007 : tax
    cmp.l !PPListN : bcc .entry
    lda #$0000 : sta.l !PPListN
.done:
    plx : pla
    plp
    rtl

; ---- palettes 8/9 into !PPPal ----
; Color j of P3 (P4): the game's palette 0 (1) color j, except where P1's (P2's)
; turtle and P3's (P4's) turtle differ in ROM: P3's (P4's) color faded by K, the
; amount the game has taken off (red of color 14: ROM minus buffer).
PPPalettes:
    lda #$0000 : sta.l !PPOff
    lda $D0 : ldy.w #!P3_info : jsr .one
    lda #$0020 : sta.l !PPOff
    lda $D2 : ldy.w #!P4_info : jsr .one
    rts
.one:                               ; A = character of the base turtle, Y = info
    lsr : dec : and #$0003 : asl #5 : sta.l !PPBase
    lda $001A,y : and #$0003 : asl #5 : sta.l !PPOwn
    lda.w $1FF0 : beq +             ; second palette set (scripts $01:8B23-, as the
    lda.l !PPBase : clc : adc #$00A0 : sta.l !PPBase   ; game's $04:80A1)
    lda.l !PPOwn : clc : adc #$00A0 : sta.l !PPOwn
+
    lda $42 : clc : adc #$0100 : adc.l !PPOff : sta.l !PPBufA   ; bank $7E
    tax
    lda.l $7E001C,x : and #$001F : sta.l !PPI                  ; buffer color 14 red
    lda.l !PPBase : tax
    lda.l TurtlePalettes+28,x : and #$001F
    sec : sbc.l !PPI : bpl +
    lda #$0000
+   sta.l !PPK
    ldy #$0000                      ; Y = byte offset of the color (0-30)
.color:
    cpy #$0004 : bcc .buffer
    cpy #$001E : bcs .buffer
    tya : clc : adc.l !PPBase : tax
    lda.l TurtlePalettes,x : sta.l !PPI
    tya : clc : adc.l !PPOwn : tax
    lda.l TurtlePalettes,x
    cmp.l !PPI : beq .buffer
    jsr PPFade
    bra .store
.buffer:
    tya : clc : adc.l !PPBufA : tax
    lda.l $7E0000,x
.store:
    pha
    tya : clc : adc.l !PPOff : tax
    pla : sta.l !PPPal,x
    iny : iny
    cpy #$0020 : bcc .color
    rts

; A = color -> each channel minus !PPK (at least 0)
PPFade:
    sta.l !PPTmp
    lda.l !PPK : bne +
    lda.l !PPTmp
    rts
+   lda.l !PPTmp : and #$001F
    sec : sbc.l !PPK : bpl +
    lda #$0000
+   sta.l !PPI                      ; red
    lda.l !PPTmp : lsr #5 : and #$001F
    sec : sbc.l !PPK : bpl +
    lda #$0000
+   asl #5 : ora.l !PPI : sta.l !PPI    ; green
    lda.l !PPTmp : xba : lsr #2 : and #$001F
    sec : sbc.l !PPK : bpl +
    lda #$0000
+   xba : asl #2 : ora.l !PPI       ; blue
    rts

; ---- OAM builder: a P3/P4 object about to be drawn (IsPlayerSlotX, JSRed first by
; the per-object routine $00:92FB, JSLs here). Carry = the player test (clear: draw
; with the player path): mains if live (P34Live), companions never (P3's/P4's
; companion A below $04E0 had been drawn as players: hundreds of junk sprites). With the extensions active, note the first OAM entry and
; the owner, and make $92FB return through PPDrawClose, which marks the entries.
; Stack: +1 JSL return (IsPlayerSlotX), +4 JSR return (into $92FB), +6 JSL return
; of $92FB's caller (3 bytes). Keeps X, Y.
IsPlayerSlotFar:
    cpx.w #!P3_slot : beq .main
    cpx.w #!P4_slot : beq .main
    lda #$0001                      ; companions are not players (as P1's/P2's at
    sta.l !PPCarry                  ; $04E0+; P3's/P4's companion A lie below $04E0)
    lda.w #!P3_slot
    cpx.w #!P3_compA : beq PPOpen
    cpx.w #!P3_compB : beq PPOpen
    lda.w #!P4_slot
    bra PPOpen
.main:
    jsl P34Live : bcs +
    sec                             ; slots 5/7 used by other objects: not a player
    rtl
+   lda #$0000 : sta.l !PPCarry
    txa
    ; fall through
PPOpen:                             ; A = owner (P3/P4 main slot)
    php
    rep #$30
    pha
    lda.l !PPActive : beq .done
    lda $01,s : sta.l !PPOwner
    jsr PPEntryIndex : sta.l !PPStart
    lda $09,s : sta.l !PPRet        ; (+6 shifted by P and A: +9)
    lda $0B,s : sta.l !PPRet+2      ; bank (and the byte after it)
    lda.w #PPDrawClose-1 : sta $09,s
    sep #$20
    lda.b #PPDrawClose>>16 : sta $0B,s
    rep #$20
.done:
    pla
    plp
    lda.l !PPCarry : lsr            ; carry = the player test
    rtl

; A = index of the next OAM entry the builder writes: 4 per high-table byte done
; ($02 from $03E0) plus the entries in the byte being collected in $1E (marker =
; lowest set bit: $80, $20, $08, $02 for 0-3).
PPEntryIndex:
    lda.l !PPExt : beq +
    lda $02 : cmp.w #!PPExtHigh : bcc .all          ; extended full ($02 wrapped)
    sec : sbc.w #!PPExtHigh-$20 : bra ++            ; extended: 128 + ...
+   lda $02 : cmp #$03E0 : bcc .all                 ; full
    sec : sbc #$03E0
++  asl #2 : sta.l !PPI
    lda $1E : and #$00FF            ; the marker is the lowest set bit (the entries'
    bit #$0002 : bne .k3            ; size/X bits come in above it)
    bit #$0008 : bne .k2
    bit #$0020 : bne .k1
    lda #$0000 : bra .add
.k3: lda #$0003 : bra .add
.k1: lda #$0001 : bra .add
.k2: lda #$0002
.add:
    clc : adc.l !PPI
    rts
.all:
    lda #$0100
    rts

; the P3/P4 object's draw routine returned here (flags = its result)
PPDrawClose:                        ; (DB = $08: low WRAM by absolute addressing)
    php
    rep #$30
    pha : phx : phy
    jsr PPEntryIndex : sta.w !PPEnd
    lda.w !PPOwner : cmp.w #!P3_slot : beq +
    lda #$0030 : sta.w !PPLo        ; P4: tiles $030-$05F, palette 1
    lda #$0200 : sta.w !PPPalBits
    bra ++
+   lda #$0000 : sta.w !PPLo        ; P3: tiles $000-$02F, palette 0
    sta.w !PPPalBits
++  lda.w !PPStart : tay
.entry:
    cpy.w !PPEnd : bcs .done
    tya : cmp #$0080 : bcs .ext
    asl #2 : tax                    ; shadow OAM entry ($01E0 + 4 n)
    lda.w $01E2,x
    bra .got
.ext:
    and #$007F : asl #2 : tax       ; extended shadow
    lda.l !PPExtLow+2,x
.got:                               ; A = tile | attribute << 8
    sta.w !PPTmp
    ldx #$0000
    and #$01FF : sec : sbc.w !PPLo : cmp #$0030 : bcs +
    inx                             ; tile in its region: page bit
+   lda.w !PPTmp : and #$0E00 : cmp.w !PPPalBits : bne +
    inx : inx                       ; its own palette: bank bit
+   txa : beq .next
    sta.w !PPTmp
    tya : and #$0003 : asl #2 : ora.w !PPTmp : tax
    lda.l PPShiftTab,x              ; bits << 2 (n mod 4)
    sta.w !PPTmp
    tya : lsr #2 : tax
    sep #$20
    lda.w !PPAttr,x : ora.w !PPTmp : sta.w !PPAttr,x
    rep #$20
.next:
    iny
    bra .entry
.done:
    lda.w !PPRet : inc : sta.w !PPRet   ; RTL target = pushed address + 1
    ply : plx : pla
    plp
    jml [!PPRet]

; (n mod 4) * 4 + bits -> bits << 2 (n mod 4)
PPShiftTab:
    db $00, $01, $02, $03, $00, $04, $08, $0C, $00, $10, $20, $30, $00, $40, $80, $C0

; ---- P3/P4 frame upload ($04:93A0 and $04:93D2; was JSL $008D8D): A = source,
; $00 = bank, Y = VRAM word, X = bytes. With the extensions active: to the extra tiles. ----
PPStream:
    pha
    lda.l !PPActive : bne +
    jmp .orig
+   lda $1864 : cmp #$0004 : bcs +
    jmp .orig
+
    tya : sec : sbc #$6000 : asl : tay  ; port address
    lda $00 : sta.l !PPBank
    pla
    jsr PPAdd
    rtl
.orig:
    pla
    jml $008D8D

; ---- $00:93A0: OAM full (the low byte of the high-table pointer $02 wrapped; A
; 8-bit; was SEC / REP #$20 / RTL). Extensions active and not yet extended: carry on
; in the extended OAM. ----
PPWrap:
    lda.l !PPActive : beq .full
    lda.l !PPExt : bne .full
    lda #$01 : sta.l !PPExt
    rep #$30
    phx : phy
    jsr PPQueueExt                  ; filled during this frame, uploaded in its NMI
    ply : plx
    lda.w #!PPExtHigh : sta $02
    sep #$20
    lda.b #!PPExtLow : sta $2181    ; WRAM port to the extended shadow
    lda.b #!PPExtLow>>8 : sta $2182
    lda.b #!PPExtLow>>16&1 : sta $2183
    jml $0093BB                     ; LDA #$80 / STA $1E / CLC / BRA (next entry)
.full:
    sec
    rep #$20
    rtl

; ---- $00:91C7, builder done (was STZ $00 / SEP #$20 / LDA $1E): extended OAM:
; finish its last high-table byte, hide entries no longer used, and give the
; original code "128 entries used" so its hide routine does nothing. ----
PPEnd:                              ; (A 16-bit)
    lda.l !PPExt : ora.l !PPExtUsed : bne .full
    stz $00                         ; nothing extended: as the original
    sep #$20
    lda $1E
    rtl
.full:
    php
    rep #$30
    lda.l !PPExt : bne .ext
    lda.l !PPExtUsed : beq +        ; not extended, but some were in use: hide them
    jsr PPQueueExt
+   lda #$0000 : bra .hide          ; (and upload)
.ext:
    jsr PPEntryIndex : sec : sbc #$0080 : pha   ; extended entries used
    sep #$20
    lda $1E : cmp #$80 : beq +      ; partial high-table byte (as $00:91CB)
-   lsr : lsr : bcc -
    sta ($02)
+   rep #$20
    lda #$0400 : sta $02            ; for the original: 128 used, nothing partial
    sep #$20
    lda #$80 : sta $1E
    rep #$20
    lda #$0000 : sta.l !PPExt
    pla
.hide:                              ; A = entries used now: hide the rest
    sta.l !PPI                      ; that were in use
    tax
-   txa : cmp.l !PPExtUsed : bcs +
    asl #2 : tay
    phx
    tyx
    lda.l !PPExtLow+1,x : and #$FF00 : ora #$00F0 : sta.l !PPExtLow+1,x
    plx
    inx
    bra -
+   lda.l !PPI : sta.l !PPExtUsed
    plp
    stz $00
    sep #$20
    lda $1E
    rtl

Extensions4End:
assert Extensions4End <= $20FFFF, "extensions4 code overflows bank $20"

; ---- hooks ----
org $00916C                         ; was LDA #$03E0 / STA $02
    jsl PPFrame
    nop
org $0093A0 : jml PPWrap            ; was SEC / REP #$20 / RTL (OAM full)
org $0091C7                         ; was STZ $00 / SEP #$20 / LDA $1E
    jsl PPEnd
    nop : nop
org $0493A0 : jsl PPStream          ; was JSL $008D8D
org $0493D2 : jsl PPStream          ; was JSL $008D8D
