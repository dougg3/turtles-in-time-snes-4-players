; Bonus tally of Scenes 3 and 8 (Sewer Surfin', Neon Night-Riders) for up to four
; players.
;
; During these scenes the game counts each player's defeated enemies in a 10-byte
; block (P1 $1911, P2 $191B): +0 foot soldiers ($03:B495), +2 a second kind
; ($03:B8D3), +4 a third ($03:D52E), +6 perfect-clear bonus (in P1's block it first
; counts the enemies spawned, $03:B8CF), +8 total. At the end a tally object
; ($03:B527, states at $03:B536) shows 1P/2P columns, gives 50 to every player if
; all spawned enemies were defeated, and counts the totals into the scores.
; The counters credited P3/P4 to P2. Now P3/P4 have blocks of their own, and in
; 3P/4P the tally shows four columns (moved left to fit) and pays every player.
; 1P/2P: the original tally (the counters map P1/P2 exactly as before).

!T4P3Block  = $1526             ; 10 bytes each (unused RAM)
!T4P4Block  = $16B0
!T4Col      = $1D30             ; current column's header position (variables in
                                ; $1D2E-$1DBE, unused RAM)
!T4Blk      = $1D32             ; current block
!T4I        = $1D34             ; player index * 2
!T4Tmp      = $1D36
!T4Pres     = $1D38             ; 4 words: player present at the tally's start
!T4Call     = $1D40             ; T4ForEach: routine to call

Orig_Text1   = $04DBA9          ; A = text (bank $01), Y = BG3 map position
Orig_Text2   = $04DBB0          ; same, other palette
Orig_Digits  = $04D985          ; A = two BCD digits, Y = position
Orig_AddPts  = $04D844          ; A = points, Y = info block
Orig_Div     = $008B12          ; A / Y -> A quotient, Y remainder

org $20D000
assert Enemies4End <= $20D000, "enemies4 code runs into tally4"

T4Blocks:   dw $1911, $191B, !T4P3Block, !T4P4Block
T4Infos:    dw !P1_info, !P2_info, !P3_info, !P4_info
T4Headers:  dw $50B2, $50B5, $50B8, $50BB       ; columns 18, 21, 24, 27, row 5
T4Labels:   dw $B756, $B759, T4Text3, T4Text4   ; "1P" "2P" (bank $01) "3P" "4P"

; ---- counters: object (A) -> X = its player's block. Attack objects (companion B)
; and player objects; anything else counts for P2, as the original's else-branch.
T4BlockFromA:
    ldx #$1911
    cmp.w #!P1_compB : beq .done
    cmp.w #!P1_slot : beq .done
    ldx.w #!T4P3Block
    cmp.w #!P3_compB : beq .done
    cmp.w #!P3_slot : beq .done
    ldx.w #!T4P4Block
    cmp.w #!P4_compB : beq .done
    cmp.w #!P4_slot : beq .done
    ldx #$191B
.done:
    rtl

; ---- dispatcher ($03:B527; was LDA $16,X / PHX / ASL / TAX / LDA $03B536,X ...) ----
T4Dispatch:
    lda.l !PlayerMode : and #$00FF : cmp #$0003 : bcs .four
    lda $16,x : asl : phx : tax
    lda.l $03B536,x
    plx
    sta $00
    sep #$20 : lda #$03 : sta $02 : rep #$20
    jml [$0000]
.four:
    lda $16,x : sta.l !T4Tmp : asl : clc : adc.l !T4Tmp : phx : tax   ; * 3
    lda.l T4States,x : sta $00
    lda.l T4States+1,x : sta $01
    plx
    jml [$0000]

; the original table ($03:B536) with the column/bonus states replaced
T4States:
    dl T4Init0, $03B585, $03B5AC, T4Bonus, $03B65A, T4ColsS3, T4Skip, $03B6CC
    dl T4Count, $03B756, T4Clear, T4Init11, $03B5EA, T4Bonus, T4Kills, $03B7D1
    dl T4Third, $03B7D1, T4Totals, $03B7D1, T4Count, $03B756, T4Clear

; ---- helpers (X = tally object unless noted) ----
; carry set while the VRAM queue is busy ($03:B27E)
T4Busy:
    lda $186A : cmp #$0002
    rts

; flash the label while there is a bonus ($03:B88D)
T4Flash:
    ldy #$5204
    lda $82 : cmp #$0007 : bne +
    ldy #$5104
+   lda $1917 : beq .done
    dec $32,x : bne .done
    lda #$0008 : sta $32,x
    lda $34,x : lsr
    lda #$B73B
    phx
    bcs +
    jsl Orig_Text1
    bra ++
+   jsl Orig_Text2
++  plx
    inc $34,x
.done:
    rts

; A = number (0-99) -> two BCD digits drawn at Y ($03:B885)
T4Number:
    phy
    ldy #$000A
    jsl Orig_Div
    sty $00
    asl #4
    ora $00
    ply
    phx
    jsl Orig_Digits
    plx
    rts

; for each present player: !T4I = index * 2, !T4Blk = its block, !T4Col = its
; column header position; calls the routine at A (bank $20, ends with RTS) with
; X = the tally object
T4ForEach:
    sta.l !T4Call
    lda #$0000 : sta.l !T4I
.loop:
    lda.l !T4I : tax
    lda.l !T4Pres,x : beq .next
    lda.l T4Blocks,x : sta.l !T4Blk
    lda.l T4Headers,x : sta.l !T4Col
    ldx $FC
    pea.w .next-1                   ; return address for the routine's RTS
    lda.l !T4Call : dec : pha
    rts                             ; "call" it
.next:
    ldx $FC
    lda.l !T4I : inc : inc : sta.l !T4I
    cmp #$0008 : bcc .loop
    rts

; A = block word offset -> A = that word of the current block
T4Word:
    clc : adc.l !T4Blk : phx : tax
    lda.l $7E0000,x
    plx
    cmp #$0000                      ; flags from the value
    rts
; A = value, Y = row offset from the column header: draw it
T4At:
    pha
    tya : clc : adc.l !T4Col : tay
    pla
    jmp T4Number

; ---- states ----
T4Init0:                            ; ($03:B564) who is in the game
    lda $9E : sta $38,x
    lda $A0 : sta $3A,x
    lda $9E : sta.l !T4Pres
    lda $A0 : sta.l !T4Pres+2
    lda.l !P3_ptr : sta.l !T4Pres+4
    lda.l !P4_ptr : sta.l !T4Pres+6
    lda $32,x : sta $16,x
    rtl

T4Init11:                           ; ($03:B571) also clear P3/P4 blocks
    jsl $03B571
    lda #$0000
    ldx #$0008
-   sta.l !T4P3Block,x
    sta.l !T4P4Block,x
    dex : dex : bpl -
    ldx $FC
    rtl

T4Bonus:                            ; ($03:B60B) totals, perfect-clear bonus
    lda #$0001 : sta $32,x
    stz $34,x
    lda #$0080 : sta $36,x
    inc $16,x
    lda #$0000 : sta.l !T4Tmp       ; sum of all totals
    ldy #$0000
-   tyx
    lda.l T4Blocks,x : tax
    lda.l $7E0000,x : clc : adc.l $7E0002,x : clc : adc.l $7E0004,x
    sta.l $7E0008,x
    clc : adc.l !T4Tmp : sta.l !T4Tmp
    iny : iny
    cpy #$0008 : bcc -
    lda #$0032                      ; 50 if every spawned enemy was defeated
    ldx $1917 : cpx.w !T4Tmp : beq +
    lda #$0000
+   sta.l !T4Tmp                    ; bonus
    ldy #$0000
-   tyx
    lda.l !T4Pres,x : beq +
    lda.l !T4Tmp
+   pha                             ; bonus for this player (0 if absent)
    lda.l T4Blocks,x : tax
    pla
    sta.l $7E0006,x
    clc : adc.l $7E0008,x : sta.l $7E0008,x
    iny : iny
    cpy #$0008 : bcc -
    ldx $FC
    rtl

T4ColsS3:                           ; ($03:B692) Scene 3: all columns
    jsr T4Busy : bcs .done
    jsr T4Flash
    lda.w #.col : jsr T4ForEach
    inc $16,x
.done:
    rtl
.col:                               ; header and the five values ($03:B860)
    jsr T4Header
    ldx #$0000
-   phx
    txa : jsr T4Word
    pha
    lda.l T4RowOffsets,x : tay
    pla
    jsr T4At
    plx
    inx : inx
    cpx #$000A : bcc -
    rts
T4RowOffsets: dw $0060, $00A0, $00E0, $0160, $01E0

T4Header:
    lda.l !T4I : tax
    lda.l T4Labels,x
    pha
    lda.l !T4Col : tay
    pla
    phx : jsl Orig_Text1 : plx
    rts

T4Skip:                             ; ($03:B6AF) P2's column: drawn already
    jsr T4Busy : bcs +
    jsr T4Flash
    inc $16,x
+   rtl

T4Kills:                            ; ($03:B774) Scene 8: labels, header, +0 and +2
    jsr T4Busy : bcs .done
    ldy #$5104 : lda #$B70D : phx : jsl Orig_Text2 : plx
    ldy #$5144 : lda #$B728 : phx : jsl Orig_Text2 : plx
    lda.w #.col : jsr T4ForEach
    lda #$0050 : sta $3C,x
    inc $16,x
.done:
    rtl
.col:
    jsr T4Header
    lda #$0000 : jsr T4Word : ldy #$0060 : jsr T4At
    lda #$0002 : jsr T4Word : ldy #$00A0 : jsr T4At
    rts

T4Third:                            ; ($03:B7D8) Scene 8: +4
    jsr T4Busy : bcs .done
    ldy #$5104 : lda #$B72D : phx : jsl Orig_Text2 : plx
    ldy #$5144 : lda #$B75C : phx : jsl Orig_Text2 : plx
    lda.w #.col : jsr T4ForEach
    lda #$0050 : sta $3C,x
    inc $16,x
.done:
    rtl
.col:
    lda #$0004 : jsr T4Word : ldy #$0060 : jsr T4At
    rts

T4Totals:                           ; ($03:B811) Scene 8: +6 bonus and +8 total
    jsr T4Busy : bcs .done
    ldy #$5104 : lda #$B73B : phx : jsl Orig_Text2 : plx
    ldy #$5144 : lda #$B748 : phx : jsl Orig_Text2 : plx
    lda.w #.col : jsr T4ForEach
    lda #$0048 : sta $3C,x
    lda #$0001 : sta $36,x
    inc $16,x
.done:
    rtl
.col:
    lda #$0006 : jsr T4Word : ldy #$0060 : jsr T4At
    lda #$0008 : jsr T4Word : ldy #$00A0 : jsr T4At
    rts

T4Count:                            ; ($03:B6D8) totals into the scores
    jsr T4Flash
    dec $36,x : bne .done
    lda #$0002 : sta $36,x
    stz $32,x
    lda.w #.one : jsr T4ForEach
    lda $32,x : bne +
    lda #$00C0 : sta $36,x
    inc $16,x
.done:
    rtl
+   lda #$004D : jsl $00839D        ; sound
    rtl
.one:
    lda #$0008 : jsr T4Word : beq .none
    dec
    pha
    lda.l !T4Blk : tax : pla : sta.l $7E0008,x
    lda.l !T4I : tax
    lda.l T4Infos,x : tay
    lda #$0001
    ldx $FC
    phx : jsl Orig_AddPts : plx
    lda #$0008 : jsr T4Word
    ldy #$01E0                      ; Scene 3: row 20
    pha
    lda $82 : cmp #$0002 : beq +
    ldy #$00A0                      ; Scene 8: row 10
+   pla
    jsr T4At
    inc $32,x
.none:
    rts

T4Clear:                            ; ($03:B760) restore the overlay area, 7 blocks
    lda $186A : bne +               ; wide instead of 6 (columns 4-31: the 4P column)
    ldy.w #T4ClearSpec
    lda #$50A4
    jsl $04FCCB
    jsl $0486BE
+   rtl

Tally4End:
assert Tally4End <= $20FFFF, "tally4 code overflows bank $20"

; "3P", "4P" for the text routine (bank $01, DB = $01 there)
org $01FF00
T4Text3: db $73, $BF, $FF
T4Text4: db $74, $BF, $FF
T4ClearSpec:                        ; as $01:B783 (6 x 5 blocks of $6F20), 7 wide
    db 7, 5
    !i = 0
    while !i < 35
        dw $6F20
        !i #= !i+1
    endwhile
T4ClearSpecEnd:
assert T4ClearSpecEnd <= $01FFB0, "tally data overflows bank $01 padding"

; ---- hooks ----
org $03B527 : jml T4Dispatch        ; was LDA $16,X / PHX / ASL / TAX / LDA $03B536,X ...
org $03B497                         ; was LDX #$1911 / CMP #$05C0 / BEQ / LDX #$191B
    jsl T4BlockFromA
    nop #7
assert pc() == $03B4A2
org $03B8D6                         ; same (second kind of enemy)
    jsl T4BlockFromA
    nop #7
assert pc() == $03B8E1
org $03D52B                         ; was LDX #$1911 / CMP #$0400 / BEQ / LDX #$191B
    jsl T4BlockFromA
    nop #7
assert pc() == $03D536
