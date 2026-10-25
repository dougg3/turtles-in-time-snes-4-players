#!/usr/bin/env python3
"""Per-player state coverage from 4-player bot runs (pool memrec $0400-$149F).

  player_states.py RUNDIR [RUNDIR...]     (each with s0..s9/pool.memrec)

All four bots run the same AI, so over a batch every player should reach roughly
the same object states (+$16). Prints the states P1/P2 reach that P3/P4 never do
(and the reverse), with frame counts.
"""
import os, struct, sys
from collections import Counter

LEN = 0x10A0
SLOTS = {"P1": 0x0400, "P2": 0x0470, "P3": 0x0630, "P4": 0x0710}
cnt = {p: Counter() for p in SLOTS}
for run in sys.argv[1:]:
    for s in range(10):
        f = os.path.join(run, f"s{s}", "pool.memrec")
        if not os.path.exists(f):
            continue
        d = open(f, "rb").read()
        for i in range(len(d) // LEN):
            fr = i * LEN
            for p, base in SLOTS.items():
                o = fr + base - 0x400
                if struct.unpack_from("<H", d, o + 0x14)[0] == 0:
                    continue  # no character
                cnt[p][struct.unpack_from("<H", d, o + 0x16)[0]] += 1
states = sorted(set().union(*cnt.values()))
print("state   " + "  ".join(f"{p:>7}" for p in SLOTS))
for st in states:
    row = [cnt[p][st] for p in SLOTS]
    flag = ""
    if min(row[:2]) > 0 and min(row[2:]) == 0:
        flag = "  <- P1/P2 only"
    elif min(row[2:]) > 0 and max(row[:2]) == 0:
        flag = "  <- P3/P4 only"
    elif 0 in row:
        flag = "  (some players 0)"
    print(f"${st:02X}     " + "  ".join(f"{c:>7}" for c in row) + flag)
