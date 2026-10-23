; ROM expanded from 1 MB to 2 MB. Banks $20-$3F (LoROM, $8000-$FFFF each) hold new code and data;
; the original banks only get hooks and small stubs.

org $00FFD7 : db $0B            ; header ROM size: 2 MB (was $0A, 1 MB)
org $3FFFFF : db $FF            ; extend the file to 2 MB

!NewCodeBank = $20              ; bank $20: four-player HUD (hud4.asm)
