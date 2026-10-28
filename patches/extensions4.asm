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
!PPIceP3    = $1D46             ; non-zero: P3 frozen (ice palette; scripts4 ScrFreeze4)
!PPIceP4    = $1D48
!PPShift1   = $1D4E             ; PPShift: shift seen on P1's palette
!PPShiftHud = $1D50             ;          screen fade from the HUD's white
!PPRec      = $1D52             ; PPLiveShift: ROM record of the turtle
!PPLive     = $1D54             ;              its live palette (bank $7E)
!PPCmp      = $1D56
!M7Tab      = $1D5C             ; M7BFrame: HDMA table address per value (6 words,
                                ; $1D5C-$1D67: A, B, C, D, H scroll, V scroll)
!M7Tmp      = $1D68
!M7Head     = $1D6A             ; M7BFrame: next history slot (0-31)
!M7Fill     = $1D6C             ;           frames in the history (0-32)
!M7Tmp2     = $1D6E
!M7Hist     = $7F1280           ; 32 slots x 24 bytes: both bands' A, B, C, D, H, V
                                ; (high WRAM never used by the game)
!M7Buf      = $7F1700           ; the second layer's settings ($90 bytes, port $4600),
                                ; uploaded in the next vblank
!M7Ptr      = $7F1790           ; M7BFrame: next byte in !M7Buf
!M7Queued   = $7F1792           ;           non-zero: settings were queued last frame
!M7Delay    = 20                ; P3/P4 copy their partner's band from 20 frames ago
!PPListN    = $1CF0             ; bytes used in !PPList
!PPList     = $7E7F00           ; uploads for the next NMI: source (3), port address
!PPListMax  = 9*7               ; (2), bytes (2); 9 entries
!PPCarry    = $1CF2             ; IsPlayerSlotFar: result of the player test             ; palettes 8/9 in the PPU are current for the key
!PPActive   = $1CC0             ; this frame: P3/P4 use the extensions
!PPStart    = $1CC2             ; first OAM entry of the P3/P4 object being drawn
!PPOwner    = $1CC4             ; its slot
!PPRet      = $1CC6             ; 3 bytes: where the object's draw routine returns to
!PPK        = $1CCA             ; signed color shift for palettes 8/9 (PPShift)
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
; and the HUD shows half-updated settings. All of them go after NMI: the sound
; CPU is stopped during extra lines, and the sound uploads run in the idle loop
; ($00:8154), which must get its time in normal lines.
!PPExtraCpu     = 0             ; before NMI
!PPExtraVblank  = 255           ; after NMI: frame logic and DMA (4P lag <= 2P lag)
; After a lag frame (the NMI found the previous one still running, $00:8190) also
; !PPBoostCpu lines before NMI for !PPBoostFrames frames: a lagging game has no idle
; time for the sound uploads anyway. All four turtles shocked in Scene 8 (X-ray
; frames uploaded every frame) lagged every other frame with 208 after NMI alone.
!PPBoostCpu     = 32
!PPBoostFrames  = 60
!PPBoost        = $1CFE         ; frames of boost left

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
    jsr PPExtraTime                 ; extra CPU time and vblank
    rep #$20
    lda #$0000                      ; attributes: none yet (set while drawing)
    ldx #$003E
-   sta.l $7E0000+!PPAttr,x
    dex : dex : bpl -
    ; palettes 8/9: rebuilt when their sources changed, sent every frame (64 bytes,
    ; like the attributes) so a lost upload can't leave P3/P4 black
    jsr PPPalCheck : bcc +
    jsr PPPalettes
+   lda.w #!PPPal : ldy #$4400 : ldx #$0040 : jsr PPQueue
    lda.w #!PPAttr : ldy #$4300 : ldx #$0040 : jsr PPQueue
    bra .done
.off:
    lda #$0000 : sta.l !PPPalOK     ; make palettes 8/9 again when switched on
    sep #$20
    lda #$00 : sta.l $0021C5        ; (on a SNES: unused B-bus addresses)
    sta.l $0021C6
    rep #$20
    lda.l $000070 : and #$00FF : cmp #$0019 : bne .m7reset
    lda.l !PlayerMode : and #$00FF : cmp #$0003 : bcc .m7off
    jsl PPPresent : bcc .m7off
    jsr M7BFrame                    ; time warp: P3/P4 on the second Mode 7 layer
    bra .done
.m7reset:
    lda #$0000 : sta.l !M7Fill      ; a new time warp starts with an empty history
.m7off:
    jsr M7BOff                      ; extensions off
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
    jsr PPOwnKey : cmp.l !PPPalKey+4 : bne .changed
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
    jsr PPOwnKey : sta.l !PPPalKey+4
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
    ; keep channel 0 as the game left it: entries are listed when $1ED2 >= 2 in the
    ; previous frame, but the game may set up its own channel 0 HDMA in between (Scene
    ; 8 intro, $1ED2 8 -> 0: a CGRAM gradient). Left aimed at $21C2, that HDMA wrote
    ; 41 bytes per frame into the port (palette 8 overwritten: black Raph).
    lda.l $004300 : pha             ; DMAP/BBAD, A1T, A1B/DAS low, DAS high
    lda.l $004302 : pha
    lda.l $004304 : pha
    sep #$20
    lda.l $004306 : pha
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
    sep #$20
    pla : sta.l $004306
    rep #$20
    pla : sta.l $004304
    pla : sta.l $004302
    pla : sta.l $004300
.done:
    plx : pla
    plp
    rtl

; ---- palettes 8/9 into !PPPal ----
; Colors 2-14 of P3 (P4): P3's (P4's) own turtle colors from ROM, faded by K, the
; amount the game's screen fade has taken off (31 - red of the HUD's white, as
; HudNmi). Colors 0, 1, 15 (0 in every turtle palette in ROM): the game's palette
; 0 (1). Built only from ROM and the screen fade, so effects on P1's/P2's palette
; (freeze, flashes) no longer show on P3/P4.
PPPalettes:
    jsr PPShift
    lda #$0000 : sta.l !PPOff
    lda $D0 : ldy.w #!P3_info : jsr .one
    lda #$0020 : sta.l !PPOff
    lda $D2 : ldy.w #!P4_info : jsr .one
    rts
.one:                               ; A = character of the base turtle, Y = info
    lsr : dec : and #$0003 : asl #5 : sta.l !PPBase
    jsr PPOwnIdx : asl #5 : sta.l !PPOwn
    lda.w $1FF0 : beq +             ; second palette set (scripts $01:8B23-, as the
    lda.l !PPOwn : cmp #$0080 : beq +   ; game's $04:80A1); not the ice palette
    clc : adc #$00A0 : sta.l !PPOwn
+
    ldx $42                         ; the game's CGRAM buffer (bank $7E)
    txa : clc : adc #$0100 : adc.l !PPOff : sta.l !PPBufA   ; palette 0 (1)
    ldy #$0000                      ; Y = byte offset of the color (0-30)
.color:
    cpy #$0004 : bcc .buffer
    cpy #$001E : bcs .buffer
    tya : clc : adc.l !PPOwn : tax
    lda.l TurtlePalettes,x
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

; Y = P3's/P4's info block -> A = palette index in TurtlePalettes: the turtle
; (info +$1A), or 4 = the ice palette ($09:9379, the game's freeze record $01:93EF)
; while that player is frozen (state $16 with its freeze flag set)
PPOwnIdx:
    phx
    ldx.w #!P3_ptr : lda.w #!PPIceP3
    cpy.w #!P3_info : beq +
    ldx.w #!P4_ptr : lda.w #!PPIceP4
+   sta.l !PPTmp
    lda $0000,x : beq .turtle       ; player pointer
    tax
    lda $16,x : cmp #$0016 : bne .turtle
    lda.l !PPTmp : tax
    lda $0000,x : beq .turtle
    plx
    lda #$0004
    rts
.turtle:
    plx
    lda $001A,y : and #$0003
    rts

; key word: effective palette index of P3 (high byte) and P4 (low byte)
PPOwnKey:
    phy
    ldy.w #!P3_info : jsr PPOwnIdx : xba : sta.l !PPI
    ldy.w #!P4_info : jsr PPOwnIdx : ora.l !PPI
    ply
    rts

; ---- time-warp vortex (mode $19): the game shows one Mode 7 picture of a
; turtle in two bands (HDMA: matrix, scroll, and colors 10/11 = the turtle's
; bandana from $01:E16F; P1's band on top, P2's below). P3 and P4 tumble on the
; second Mode 7 layer in their partner's band, on the
; mirrored side of the screen, !M7Delay frames behind (another angle and size, so
; they don't look like reflections), with their own bandanas. Runs from the OAM
; builder, while the screen is drawn: the layer's settings go to !M7Buf and are
; uploaded in the next vblank, and the layer is switched on from the frame after
; the first upload (settings written or the layer switched mid-frame would show
; on part of the screen). ----
M7BOff:
    lda #$0000 : sta.l !M7Queued
    sep #$20
    lda #$00 : sta.l $0021C4        ; second Mode 7 layer (and the extensions) off
    rep #$20
    rts

M7BFrame:
    ; the game's HDMA channels, by destination: A $1B, B $1C, C $1D, D $1E,
    ; H scroll $0D, V scroll $0E -> table address (bank $7E)
    ldx #$000A
    lda #$0000
-   sta.l !M7Tab,x
    dex : dex : bpl -
    ldy #$0000                      ; Y = channel * $10
.chan:
    tyx
    lda.l $004301,x : and #$00FF    ; destination
    ldx #$000A
-   cmp.l .dests,x : beq +
    dex : dex : bpl -
    bra .nextchan
+   phx
    tyx
    lda.l $004302,x                 ; table address
    plx
    sta.l !M7Tab,x
.nextchan:
    tya : clc : adc #$0010 : tay
    cpy #$0080 : bcc .chan
    ldx #$000A                      ; all six found, tables in the expected shape:
-   lda.l !M7Tab,x : beq .off       ; 1 line, n1 lines, n2 lines, end
    phx
    tax
    lda.l $7E0000,x : and #$00FF : cmp #$0001 : bne .bad
    lda.l $7E0003,x : and #$0080 : bne .bad
    lda.l $7E0006,x : and #$0080 : bne .bad
    lda.l $7E0009,x : and #$00FF : bne .bad
    plx
    dex : dex : bpl -
    bra .ok
.bad:
    plx
    lda #$0000 : sta.l !M7Fill      ; another Mode 7 picture (planet): start over
.off:
    jmp M7BOff
.ok:
    ; history: this frame's band values into the next slot
    lda.l !M7Head : jsr .slot : sta.l !M7Tmp
    ldx #$0000
-   phx
    lda.l !M7Tab,x : tax
    lda.l $7E0004,x : pha           ; band 1 (P1's)
    lda.l $7E0007,x : pha           ; band 2 (P2's)
    lda 5,s : clc : adc.l !M7Tmp : tax
    pla : sta.l !M7Hist+12,x
    pla : sta.l !M7Hist,x
    plx
    inx : inx
    cpx #$000C : bcc -
    lda.l !M7Head : inc : and #$001F : sta.l !M7Head
    lda.l !M7Fill : cmp #$0020 : bcs +
    inc : sta.l !M7Fill
+   cmp.w #!M7Delay+1 : bcs +       ; not enough history yet: P3/P4 not shown
    jmp M7BOff
+
    lda.l !M7Head : sec : sbc.w #!M7Delay+1 : and #$001F : jsr .slot
    sta.l !M7Tmp                    ; the slot shown
    lda #$0000 : sta.l !M7Ptr       ; settings from the start of !M7Buf (port $4600)
    lda.l !M7Tab : tax              ; split = 1 + n1 (the second band's first line)
    lda.l $7E0003,x : and #$00FF : inc
    jsr .byte
    ldx #$000F : jsr .zeros
    jsl WarpPlayers                 ; the game's bands show the first two players in
    ldx #$0004 : jsr .who           ; the game (warp4.asm); band 1's copy the third,
    lda #$0000 : jsr .set
    ldx #$0006 : jsr .who           ; band 2's copy the fourth
    lda #$000C : jsr .set
    lda #$007F : sta.l !PPBank      ; upload in the next vblank
    lda.w #!M7Buf : ldy #$4600 : ldx #$0090 : jsr PPAdd
    lda.l !M7Queued : beq +         ; settings uploaded in this frame's vblank:
    sep #$20
    lda #$04 : sta.l $0021C4        ; second Mode 7 layer on
    rep #$20
+   lda #$0001 : sta.l !M7Queued
    rts
.slot:                              ; A = slot -> A = slot * 24
    asl #3 : pha : asl : clc : adc 1,s : sta 1,s : pla
    rts
; X = position * 2 in the warp list -> Y = that player's info block (0: nobody)
.who:
    ldy #$0000
    txa : lsr : cmp.l !WarpN : bcs +
    lda.l !WarpList,x : tax
    lda.l WarpInfos,x : tay
+   rts
; A = band offset in the slot (0 or 12), Y = info block of the player shown (0:
; nobody, set off): one $40-byte set
.set:
    clc : adc.l !M7Tmp : sta.l !M7Tmp2
    phy
    ldx #$0000
-   phx
    txa : clc : adc.l !M7Tmp2 : tax
    lda.l !M7Hist,x
    jsr .word
    plx
    inx : inx
    cpx #$000C : bcc -
    ldx #$0004 : jsr .zeros
    lda #$0C00 : jsr .word          ; colors 10 and 11 from the set
    lda 1,s : beq +                 ; somebody: enabled, screen mirrored
    lda #$0003
+   jsr .byte
    ldx #$000D : jsr .zeros
    ldx #$0014 : jsr .zeros         ; colors 0-9 (not used)
    ply
    tya : beq +                     ; (nobody: any colors)
    lda $001A,y
+   and #$0003 : asl #2 : tax       ; turtle -> $01:E16F (colors 10, 11)
    lda.l $01E16F,x : jsr .word
    lda.l $01E171,x : jsr .word
    ldx #$0008                      ; colors 12-15
.zeros:                             ; X bytes of 0
-   lda #$0000 : jsr .byte
    dex : bne -
    rts
.word:
    pha : jsr .byte : pla : xba
.byte:                              ; A low -> the next byte of !M7Buf (A, X kept)
    phx : pha
    lda.l !M7Ptr : tax
    inc : sta.l !M7Ptr
    lda 1,s
    sep #$20
    sta.l !M7Buf,x
    rep #$20
    pla : plx
    rts
.dests: dw $001B, $001C, $001D, $001E, $000D, $000E

;!PPK = signed shift for palettes 8/9, the fade the game applies to the turtles:
; measured on P1's and P2's live palettes (0/1) against their turtles' ROM colors
; when both show the same uniform shift (fades to black and to white, e.g. the
; turtles fading to white after the Technodrome); otherwise (one player's own
; effect: ice, flashes) the screen fade from the HUD's white, -(31 - red).
PPShift:
    ldx $42
    lda.l $7E000C,x : and #$001F : sec : sbc #$001F : sta.l !PPShiftHud
    lda $D0 : ldy #$0100 : jsr PPLiveShift : bcc .hud
    sta.l !PPShift1
    lda $D2 : ldy #$0120 : jsr PPLiveShift : bcc .hud
    cmp.l !PPShift1 : bne .hud
    sta.l !PPK
    rts
.hud:
    lda.l !PPShiftHud : sta.l !PPK
    rts

; A = character, Y = its palette's offset in the CGRAM buffer -> carry set and
; A = shift if colors 2, 4 and 8 are its ROM colors shifted uniformly. Color 8
; has blue 0 and red 27-31 in every turtle palette: lighter = its blue, darker = its
; red minus the ROM red (all black when red is 0).
PPLiveShift:
    lsr : dec : and #$0003 : asl #5
    ldx.w $1FF0 : beq +
    clc : adc #$00A0                ; second palette set
+   sta.l !PPRec
    tya : clc : adc $42 : sta.l !PPLive
    tax : lda.l $7E0010,x           ; live color 8
    xba : lsr #2 : and #$001F : beq .down
    sta.l !PPK : bra .check
.down:
    lda.l $7E0010,x : and #$001F : bne +
    lda #$FFE1 : sta.l !PPK : bra .check    ; -31
+   sta.l !PPK
    lda.l !PPRec : tax
    lda.l TurtlePalettes+$10,x : and #$001F
    eor #$FFFF : inc : clc : adc.l !PPK : sta.l !PPK
.check:
    ldy #$0004 : jsr .cmp : bne .no
    ldy #$0008 : jsr .cmp : bne .no
    ldy #$0010 : jsr .cmp : bne .no
    lda.l !PPK
    sec
    rts
.no:
    clc
    rts
.cmp:                               ; Y = byte offset of a color: Z set if equal
    tya : clc : adc.l !PPRec : tax
    lda.l TurtlePalettes,x : jsr PPFade : sta.l !PPCmp
    tya : clc : adc.l !PPLive : tax
    lda.l $7E0000,x : cmp.l !PPCmp
    rts

; A = color -> each channel + !PPK (signed), kept within 0-31
PPFade:
    sta.l !PPTmp
    lda.l !PPK : bne +
    lda.l !PPTmp
    rts
+   lda.l !PPTmp : and #$001F : jsr .ch
    sta.l !PPI                      ; red
    lda.l !PPTmp : lsr #5 : and #$001F : jsr .ch
    asl #5 : ora.l !PPI : sta.l !PPI    ; green
    lda.l !PPTmp : xba : lsr #2 : and #$001F : jsr .ch
    xba : asl #2 : ora.l !PPI       ; blue
    rts
.ch:
    clc : adc.l !PPK : bpl +
    lda #$0000
    rts
+   cmp #$0020 : bcc +
    lda #$001F
+   rts

; ---- an enemy held by P3/P4 (grab, slam, lift/throw): its frames come from the
; holder's upload area (lists at $01:B8AD/B8BD/B8CD; P3 uses P1's, P4 P2's), so its
; entries get the holder's tile page. PPDrawClose sets the page only for tiles in
; the holder's range ($00-$2F / $30-$5F), which enemies' own graphics never use, so
; "held by P3/P4" (+$34) is enough (+$06 is not a "player-area frame" flag: it is
; clear in about half of the held frames). Drawn as an ordinary object
; (carry set). JSLed by IsPlayerSlotX with the same stack layout as IsPlayerSlotFar.
HeldEnemyTest:
    cpx #$08D0 : bcc .no            ; enemy slots
    lda $34,x                       ; holder
    cmp.w #!P3_slot : beq .held
    cmp.w #!P4_slot : beq .held
.no:
    sec
    rtl
.held:
    pha
    lda #$0001 : sta.l !PPCarry
    pla
    jmp PPOpen

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

; $21C5/$21C6 for the next frame (A 8-bit on entry and exit): four players and more
; sprites need both; the boost after a lag frame (PPLagNmi)
PPExtraTime:
    rep #$20
    lda.l !PPBoost : beq +
    dec : sta.l !PPBoost
    lda.w #!PPBoostCpu : bra ++
+   lda.w #!PPExtraCpu
++  sep #$20
    sta.l $0021C5
    lda.b #!PPExtraVblank : sta.l $0021C6
    rts

; ---- $00:93A0: OAM full (the low byte of the high-table pointer $02 wrapped; A
; 8-bit; was SEC / REP #$20 / RTL). Extensions active and not yet extended: carry on
; in the extended OAM. ----
PPWrap:
    lda.l !PPActive : beq .full
    lda.l !PPExt : bne .full
    jsr PPWrapStart
    jml $0093BB                     ; LDA #$80 / STA $1E / CLC / BRA (next entry)
.full:
    sec
    rep #$20
    rtl

; ---- $00:92D5: the same for the player draw path (turtles; full exit of its
; high-table step at $00:92EF, was SEC / REP #$20 / RTL). Without it a turtle
; drawn when OAM filled up lost its remaining pieces. ----
PPWrapPlayer:
    lda.l !PPActive : beq PPWrap_full
    lda.l !PPExt : bne PPWrap_full
    jsr PPWrapStart
    jml $0092F1                     ; CLC / LDA #$80 / BRA $92C5 (next entry)

PPWrapStart:                        ; (A 8-bit) continue in the extended shadow
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
    rts

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
org $008190 : jsl PPLagNmi : nop   ; was REP #$30 / JSR $8271 (NMI during the last one)
org $00FF70                         ; (free)
PPLagNmi:
    rep #$30
    jsr.w a16($008271)
    pha
    lda.l !PPActive : beq +
    lda.w #!PPBoostFrames : sta.l !PPBoost
+   pla
    rtl
PPLagNmiEnd:
%below(PPLagNmiEnd, $00FFB0, "PPLagNmi runs into the header")
org $0093A0 : jml PPWrap            ; was SEC / REP #$20 / RTL (OAM full)
org $0092D5 : jml PPWrapPlayer      ; the same in the player draw path
org $0091C7                         ; was STZ $00 / SEP #$20 / LDA $1E
    jsl PPEnd
    nop : nop
org $0493A0 : jsl PPStream          ; was JSL $008D8D
org $0493D2 : jsl PPStream          ; was JSL $008D8D
