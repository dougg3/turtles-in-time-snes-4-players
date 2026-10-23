#!/usr/bin/env python3
"""Object-pool occupancy from a memrec of WRAM $0400-$149F (38 slots x $70).

  pool_stats.py FILE.memrec

A slot counts as used when its type word (+$14) or its draw pointer (+$00) is non-zero.
"""
import sys
from collections import Counter

SLOTS, SIZE = 38, 0x70
data = open(sys.argv[1], "rb").read()
rec = SLOTS * SIZE
n = len(data) // rec
used = [0] * SLOTS
types = [Counter() for _ in range(SLOTS)]
enemies_max = 0
enemy_hist = Counter()
for f in range(n):
    fr = data[f * rec:(f + 1) * rec]
    e = 0
    for k in range(SLOTS):
        b = k * SIZE
        typ = fr[b + 0x14] | fr[b + 0x15] << 8
        ptr = fr[b] | fr[b + 1] << 8
        if typ or ptr:
            used[k] += 1
            types[k][typ] += 1
            if 11 <= k <= 19 and typ:
                e += 1
    enemy_hist[e] += 1
    enemies_max = max(enemies_max, e)
print(f"{n} frames")
for k in range(SLOTS):
    top = ", ".join(f"${t:04X}x{c}" for t, c in types[k].most_common(4))
    print(f"slot {k:2d} ${0x400 + k * SIZE:04X}: used {100 * used[k] / n:5.1f}%  types: {top}")
print("enemies (slots 11-19 with type) histogram:", dict(sorted(enemy_hist.items())), "max", enemies_max)
