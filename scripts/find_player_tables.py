#!/usr/bin/env python3
"""Find per-player lookup tables: code that loads Y from $1864 (current player
index x2, set by $00:ADF9) and then indexes a table with ,Y.

  find_player_tables.py ROM

Static scan (not CDL-limited). For each 'LDY $1864' (AC 64 18) it decodes the
next few instructions (16-bit M/X assumed, as in the player update code) and
reports absolute/long ,Y operands. Table bank = DB at runtime ($01 during the
player update, confirmed for $01:C296); verify each table before trusting it.
"""
import re
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from dis65816 import Disassembler, OPS, file_to_snes, snes_to_file  # noqa: E402

rom = open(sys.argv[1], "rb").read()
d = Disassembler(rom)
tables = {}
for m in re.finditer(rb"\xAC\x64\x18", rom):
    addr = file_to_snes(m.start())
    a, m8, x8 = addr, False, False
    for _ in range(6):
        n, text, mn, val, m8, x8 = d.decode(a, m8, x8)
        mode = OPS[rom[snes_to_file(a)]][1]
        if mode in ("absy", "longx") or (mode == "absy"):
            tables.setdefault(val, []).append(f"{a >> 16:02X}:{a & 0xFFFF:04X} {text}")
        if mn in ("RTS", "RTL", "JMP", "JML", "BRA") or (mn.startswith("LD") and "Y" in mn and a != addr and mode != "absy"):
            break
        a = (a & 0xFF0000) | ((a + n) & 0xFFFF)


def entries(t):
    fo = snes_to_file(0x010000 | t)
    return " ".join(f"{rom[fo + i] | rom[fo + i + 1] << 8:04X}" for i in range(0, 8, 2))


print(f"{len(tables)} tables indexed by the player index:")
for t, uses in sorted(tables.items()):
    print(f"  $01:{t:04X} [P1 P2 next next] = {entries(t)}   used at {', '.join(uses)}")
