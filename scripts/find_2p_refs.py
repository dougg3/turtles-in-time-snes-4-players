#!/usr/bin/env python3
"""Inventory of instructions that hard-code the two player slots.

  find_2p_refs.py ROM CDL [CDL...]

Looks for (a) immediate operands #$0400 / #$0470 (player slot bases) and
(b) absolute operands inside the two player records ($0400-$046F, $0470-$04DF).
Only executed instructions (recovered from the CDL by instruction_starts) are
scanned, so data that happens to match is excluded. Code that
was never executed in the recorded runs is therefore missing from this list.
"""
import sys
from collections import defaultdict

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from dis65816 import Disassembler, OPS, file_to_snes, instruction_starts  # noqa: E402

rom = open(sys.argv[1], "rb").read()
merged = 0
for p in sys.argv[2:]:
    merged |= int.from_bytes(open(p, "rb").read().ljust(len(rom), b"\0"), "little")
cdl = merged.to_bytes(len(rom), "little")
d = Disassembler(rom, cdl)

hits = defaultdict(list)
for fo in instruction_starts(rom, cdl):
    addr = file_to_snes(fo)
    n, text, mn, val, _, _ = d.decode(addr, None, None)
    mode = OPS[rom[fo]][1]
    if mode in ("immm", "immx") and n == 3 and val in (0x0400, 0x0470):
        hits["immediate slot base"].append(f"{addr >> 16:02X}:{addr & 0xFFFF:04X}  {text}")
    elif mode in ("abs", "absx", "absy") and 0x0400 <= val < 0x04E0:
        who = "P1" if val < 0x0470 else "P2"
        off = (val - 0x0400) % 0x70
        hits[f"absolute {who} field"].append(f"{addr >> 16:02X}:{addr & 0xFFFF:04X}  {text:<16} ; {who}+${off:02X}")
for k, v in hits.items():
    print(f"== {k}: {len(v)}")
    print("\n".join(v))
