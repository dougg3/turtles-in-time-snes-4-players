#!/usr/bin/env python3
"""Check patched code against the original's control flow.

  check_hooks.py ORIGINAL PATCHED CDL [CDL...] [--ignore BB:AAAA ...]

--ignore: branch sites to skip (known false positives: CDL decoding can start
mid-instruction, e.g. 00:C15F is inside LDA #$0020 at 00:C15E).

Uses the executed code recorded in Mesen CDL files (merged). Reports
original branches/jumps whose target lies inside overwritten bytes but not at
the start of the overwritten run (the patch broke a loop or branch target).
(Bytes a patch rewrites with their original value are not seen as overwritten.)
"""
import sys
from dis65816 import Disassembler, instruction_starts, file_to_snes, CDL_CODE

args = sys.argv[1:]
ignore = set()
if "--ignore" in args:
    k = args.index("--ignore")
    ignore = {int(a.replace(":", ""), 16) for a in args[k + 1:]}
    args = args[:k]
orig = open(args[0], "rb").read()
patched = open(args[1], "rb").read()
cdl = bytearray(len(orig))
for f in args[2:]:
    d = open(f, "rb").read()
    for i in range(min(len(d), len(cdl))):
        if d[i] & CDL_CODE:
            if cdl[i] & CDL_CODE:
                continue
            cdl[i] = d[i]

diff = [i < len(patched) and orig[i] != patched[i] for i in range(len(orig))]
starts = instruction_starts(orig, cdl)
start_set = set(starts)
dis = Disassembler(orig, cdl)
problems = 0
for fo in starts:
    addr = file_to_snes(fo)
    n, text, mn, val, _, _ = dis.decode(addr, None, None)
    tgt = None
    op = orig[fo]
    if mn in ("BRA", "BRL", "BCC", "BCS", "BEQ", "BNE", "BMI", "BPL", "BVC", "BVS"):
        tgt = val
    elif mn in ("JMP", "JSR") and op in (0x4C, 0x20):
        tgt = (addr & 0xFF0000) | val
    elif mn in ("JML", "JSL") and op in (0x5C, 0x22):
        tgt = val
    if tgt is None or (tgt & 0xFFFF) < 0x8000:
        continue
    t = ((tgt >> 16) & 0x7F) * 0x8000 + (tgt & 0x7FFF)
    if t >= len(orig) or diff[fo]:
        continue  # the branch itself was patched away
    if diff[t] and diff[t - 1] and addr not in ignore:
        print(f"BROKEN TARGET: {addr >> 16:02X}:{addr & 0xFFFF:04X} {text} -> inside patched bytes at "
              f"{tgt >> 16 & 0xFF:02X}:{tgt & 0xFFFF:04X}")
        problems += 1
print(f"{problems} problem(s)")
sys.exit(1 if problems else 0)
