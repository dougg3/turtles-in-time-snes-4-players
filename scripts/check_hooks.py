#!/usr/bin/env python3
"""Check patched code against the original's control flow.

  check_hooks.py ORIGINAL PATCHED CDL [CDL...] [--ignore BB:AAAA ...]

--ignore: branch sites to skip (known false positives: CDL decoding can start
mid-instruction, e.g. 00:C15F is inside LDA #$0020 at 00:C15E).

Uses the executed code recorded in Mesen CDL files (merged), extended statically:
branches from executed code into code no run executed are followed (M/X widths
from the branch), so rarely run paths (game over, continues) are checked too.
Reports original branches/jumps whose target lies inside overwritten bytes but
not at the start of the overwritten run (the patch broke a loop or branch target).
(Bytes a patch rewrites with their original value are not seen as overwritten.)
"""
import sys
from dis65816 import Disassembler, instruction_starts, file_to_snes, snes_to_file, CDL_CODE, CDL_M8, CDL_X8

BRANCHES = ("BRA", "BRL", "BCC", "BCS", "BEQ", "BNE", "BMI", "BPL", "BVC", "BVS")
ENDS = ("RTS", "RTL", "RTI", "STP", "BRA", "BRL", "JMP", "JML", "BRK", "COP", "WDM")


def target_of(dis, rom, addr, m8, x8):
    """(length, mnemonic, branch/jump target or None, m8, x8) of the instruction at addr."""
    n, text, mn, val, m8, x8 = dis.decode(addr, m8, x8)
    op = rom[snes_to_file(addr)]
    tgt = None
    if mn in BRANCHES:
        tgt = val
    elif mn in ("JMP", "JSR") and op in (0x4C, 0x20):
        tgt = (addr & 0xFF0000) | val
    elif mn in ("JML", "JSL") and op in (0x5C, 0x22):
        tgt = val
    return n, mn, text, tgt, m8, x8


def static_starts(rom, cdl, starts, limit=200):
    """Instruction starts of unexecuted code reached by branches from executed code."""
    dis = Disassembler(rom, None)
    seen = set(starts)
    work = []
    for fo in starts:
        m8, x8 = bool(cdl[fo] & CDL_M8), bool(cdl[fo] & CDL_X8)
        _, mn, _, tgt, m8, x8 = target_of(dis, rom, file_to_snes(fo), m8, x8)
        if tgt is not None and mn in BRANCHES and (tgt & 0xFFFF) >= 0x8000:
            work.append((tgt, m8, x8))
    extra = []
    while work:
        addr, m8, x8 = work.pop()
        for _ in range(limit):
            if (addr & 0xFFFF) < 0x8000:
                break
            fo = snes_to_file(addr)
            if fo >= len(rom) or fo in seen or cdl[fo] & CDL_CODE:
                break
            seen.add(fo)
            extra.append(fo)
            n, mn, _, tgt, m8, x8 = target_of(dis, rom, addr, m8, x8)
            if m8 is None or x8 is None:
                break
            if tgt is not None and mn in BRANCHES:
                work.append((tgt, m8, x8))
            if mn in ENDS:
                break
            addr = (addr & 0xFF0000) | ((addr + n) & 0xFFFF)
    return extra

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
extra = static_starts(orig, cdl, starts)
dis = Disassembler(orig, cdl)
problems = 0
for fo in starts + extra:
    addr = file_to_snes(fo)
    _, mn, text, tgt, _, _ = target_of(dis, orig, addr, None, None)
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
