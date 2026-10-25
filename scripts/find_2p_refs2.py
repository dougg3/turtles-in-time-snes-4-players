#!/usr/bin/env python3
"""Wider inventory of code that names P1's/P2's objects (after the attack bug).

  find_2p_refs2.py ORIGINAL_ROM PATCHED_ROM CDL [CDL...]

find_2p_refs.py only looked at the player objects; the attack bug was in
a test of the players' companion B objects. This scan covers every executed
instruction (CDLs recorded on the original ROM) whose operand names:
  - a P1/P2 object, companion A or companion B (base as immediate, or any field
    as absolute / long address),
  - a P1/P2 info block ($1A80/$1AC0),
  - the player pointers $9E/$A0 (direct page),
and prints each with "patched" when the patched ROM differs in that instruction's
bytes (hooked or repointed) or "ORIGINAL" (needs a reason to be left alone).
"""
import sys
from collections import defaultdict

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from dis65816 import Disassembler, OPS, file_to_snes, instruction_starts  # noqa: E402

orig = open(sys.argv[1], "rb").read()
patched = open(sys.argv[2], "rb").read()
merged = 0
for p in sys.argv[3:]:
    merged |= int.from_bytes(open(p, "rb").read().ljust(len(orig), b"\0"), "little")
cdl = merged.to_bytes(len(orig), "little")
d = Disassembler(orig, cdl)

# (first, last, owner, kind)
RANGES = [
    (0x0400, 0x046F, "P1", "object"), (0x0470, 0x04DF, "P2", "object"),
    (0x04E0, 0x054F, "P1", "compA"), (0x0550, 0x05BF, "P2", "compA"),
    (0x05C0, 0x062F, "P1", "compB"), (0x06A0, 0x070F, "P2", "compB"),
    (0x1A80, 0x1ABF, "P1", "info"), (0x1AC0, 0x1AFF, "P2", "info"),
]
BASES = {r[0]: f"{r[2]} {r[3]}" for r in RANGES}


def classify(val):
    for lo, hi, who, kind in RANGES:
        if lo <= val <= hi:
            return f"{who} {kind}+${val - lo:02X}"
    return None


hits = defaultdict(list)
for fo in instruction_starts(orig, cdl):
    if fo >= 0x100000:
        continue
    addr = file_to_snes(fo)
    n, text, mn, val, _, _ = d.decode(addr, None, None)
    mode = OPS[orig[fo]][1]
    what = None
    if mode in ("immm", "immx") and n == 3 and val in BASES:
        what = f"#{BASES[val]}"
    elif mode in ("abs", "absx", "absy") and mn not in ("JSR", "JMP") and val is not None:
        what = classify(val)
    elif mode in ("long", "longx") and mn not in ("JSL", "JML") and val is not None and (val >> 16) in (0x7E, 0x00):
        what = classify(val & 0xFFFF)
    elif mode in ("dp", "dpx", "dpy") and val in (0x9E, 0xA0) and mn in ("LDA", "LDX", "LDY", "CPX", "CPY", "CMP"):
        what = "P1 ptr $9E" if val == 0x9E else "P2 ptr $A0"
    if not what:
        continue
    state = "patched " if orig[fo:fo + n] != patched[fo:fo + n] else "ORIGINAL"
    hits[addr >> 16].append(f"{state} {addr >> 16:02X}:{addr & 0xFFFF:04X}  {text:<18} ; {what}")

total = sum(len(v) for v in hits.values())
orig_n = sum(1 for v in hits.values() for h in v if h.startswith("ORIGINAL"))
print(f"{total} references, {orig_n} unpatched")
for bank in sorted(hits):
    print(f"== bank ${bank:02X}")
    print("\n".join(hits[bank]))
