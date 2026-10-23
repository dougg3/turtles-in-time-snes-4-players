#!/usr/bin/env python3
"""Per-stage summary of bot runs: stage_report.py RUNDIR [RUNDIR...]

Each RUNDIR holds oam.oamrec, cpu.cpu and pool.memrec from scripts/gen_bot.py.
The first SKIP frames (stage intro/loading) are excluded, and p99 is reported
instead of max because loading/transition frames produce meaningless extremes
(NMI work spanning several frames, uninitialized OAM).
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from oam_stats import REC, frame_stats  # noqa: E402

FRAME = 357368
POOL_REC = 38 * 0x70
SKIP = 600


def pct(v, q):
    v = sorted(v)
    return v[min(len(v) - 1, int(len(v) * q))]


print("| run | frames | OAM entries p50/p95/p99 | sprites/line p99 | slivers/line p99 | frames >34 slivers | CPU busy p50/p95/p99 % | lag NMIs | enemies max | slots 2-10 max in use |")
print("|---|---|---|---|---|---|---|---|---|---|")
for d in sys.argv[1:]:
    oam = open(f"{d}/oam.oamrec", "rb").read()
    used, spr, sliv, over = [], [], [], 0
    for i in range(SKIP, len(oam) // REC):
        rec = oam[i * REC:(i + 1) * REC]
        u, s, l = frame_stats(rec[0], rec[2:])
        used.append(u)
        spr.append(max(s))
        sliv.append(max(l))
        over += any(x > 34 for x in l)
    rows = [l.split() for l in open(f"{d}/cpu.cpu") if l.strip()][SKIP:]
    busy = [100 * int(b) / FRAME for _, b, lag in rows if lag == "0"]
    lags = sum(lag == "1" for _, _, lag in rows)
    pool = open(f"{d}/pool.memrec", "rb").read()
    emax = smax = 0
    for f in range(SKIP, len(pool) // POOL_REC):
        fr = pool[f * POOL_REC:(f + 1) * POOL_REC]
        t = lambda k: fr[k * 0x70 + 0x14] | fr[k * 0x70 + 0x15] << 8
        p = lambda k: fr[k * 0x70] | fr[k * 0x70 + 1] << 8
        emax = max(emax, sum(1 for k in range(11, 20) if t(k)))
        smax = max(smax, sum(1 for k in range(2, 11) if t(k) or p(k)))
    print(f"| {d.rstrip('/').rsplit('/', 1)[-1]} | {len(used)} | {pct(used, .5)}/{pct(used, .95)}/{pct(used, .99)} | {pct(spr, .99)} | {pct(sliv, .99)} | "
          f"{over} | {pct(busy, .5):.1f}/{pct(busy, .95):.1f}/{pct(busy, .99):.1f} | {lags} | {emax} | {smax} |")
