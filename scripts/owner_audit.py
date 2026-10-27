#!/usr/bin/env python3
"""Runtime audit for two-player assumptions, with scripts/lua/owner_probe.lua.

  owner_audit.py jmps ROM OUT.lua      every 'JMP ($0000)' (object-state dispatch) as a Lua set
  owner_audit.py report OWNER.TXT...   instructions that, run for P3's/P4's objects, touch
                                       WRAM the same instruction touches only for P1 or P2

For each (instruction, read/write): S[p] = WRAM addresses it touched while an object of
player p was being processed. Reported when S1 and S2 are both seen and differ (the
instruction is player-dependent) and P3's or P4's set includes an address only P1 (or
only P2) used. Only WRAM $0020-$1FFF counts (all per-player data lives there; above it are
buffers that DMA and HDMA read, and Mesen reports those reads under the last instruction),
without the stack ($1D00-$1DFF). Instructions touching more than 24 addresses (pool
scans) are left out. Known false alarms:
code that runs between dispatches keeps the previous object's owner (e.g. the
companion loops, the state dispatchers, P3/P4 updates entered without a dispatch).
"""
import sys
from collections import defaultdict


def jmps(rom_path, out_path):
    rom = open(rom_path, "rb").read()
    sites = []
    i = rom.find(b"\x6C\x00\x00")
    while i >= 0:
        if i // 0x8000 < 0x7E:
            a = ((i // 0x8000) << 16) | (0x8000 + i % 0x8000)
            sites.append(a)
        i = rom.find(b"\x6C\x00\x00", i + 1)
    with open(out_path, "w") as f:
        f.write("return {\n" + "".join(f"[0x{a:06X}]=true,\n" for a in sites) + "}\n")


def fmt(s):
    s = sorted(s)
    return (",".join(f"{x:04X}" for x in s[:3]) + (f"+{len(s) - 3}" if len(s) > 3 else "")) if s else "-"


def report(paths):
    m = defaultdict(lambda: defaultdict(set))
    for p in paths:
        for line in open(p):
            o, k, pc, a = line.split()
            o, a = int(o), int(a, 16)
            if o > 3 or 0x1D00 <= a < 0x1E00 or a < 0x20 or a >= 0x2000:
                continue
            m[(pc, k)][o].add(a)
    rows = []
    for (pc, k), S in m.items():
        s1, s2, s3, s4 = (frozenset(S.get(o, ())) for o in range(4))
        if not (s3 or s4) or not s1 or not s2 or s1 == s2 or len(s1 | s2 | s3 | s4) > 24:
            continue
        bad = [f"{name}:{fmt(mine & (own - others))}"
               for name, mine, own, others in (("P3->P1", s3, s1, s2 | s4), ("P3->P2", s3, s2, s1 | s4),
                                               ("P4->P2", s4, s2, s1 | s3), ("P4->P1", s4, s1, s2 | s3))
               if mine & (own - others)]
        if bad:
            rows.append(f"{pc} {k}  {' '.join(bad):<34} | P1 {fmt(s1):<22} P2 {fmt(s2):<22} "
                        f"P3 {fmt(s3):<22} P4 {fmt(s4)}")
    print("\n".join(sorted(rows)))
    print(f"{len(rows)} instructions to review", file=sys.stderr)


if sys.argv[1] == "jmps":
    jmps(sys.argv[2], sys.argv[3])
else:
    report(sys.argv[2:])
