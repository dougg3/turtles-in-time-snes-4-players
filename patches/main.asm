; Root patch file. Applied by scripts/build.sh to a copy of the clean ROM.
lorom

; a 16-bit ROM pointer written in long form ($BBAAAA), so the variant builds
; (scripts/variants.py) can translate it like every other ROM address
function a16(x) = x&$FFFF

; layout checks that hold wherever the variant builds put the blocks: block [a, b)
; and block [c, d) don't overlap; a block ending at e stays below limit in its bank
macro apart(a, b, c, d, msg)
    assert <b> <= <c> || <d> <= <a>, "<msg>"
endmacro
macro below(e, limit, msg)
    assert ((<e>-1)>>16) != ((<limit>)>>16) || <e> <= <limit>, "<msg>"
endmacro

; JP=1 (scripts/build.sh jp): the Japanese version needs a few hooks of its own
if not(defined("JP"))
    !JP = 0
endif

incsrc "expand.asm"
incsrc "ram.asm"
incsrc "player_tables.asm"
incsrc "input4.asm"
incsrc "players.asm"
incsrc "player_word_array.asm"
incsrc "players4.asm"
incsrc "player_region.asm"
incsrc "hud4.asm"
incsrc "info4.asm"
incsrc "select4.asm"
incsrc "continue4.asm"
incsrc "scene8.asm"
incsrc "slots4.asm"
incsrc "extensions4.asm"
incsrc "enemies4.asm"
incsrc "tally4.asm"
incsrc "scripts4.asm"
incsrc "title4.asm"
incsrc "warp4.asm"
incsrc "cheer4.asm"
incsrc "warpin4.asm"
