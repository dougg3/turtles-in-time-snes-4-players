#!/usr/bin/env python3
"""Sprite/CPU statistics for labeled frame windows of bot runs.

  section_report.py RUNDIR:START-END:LABEL [...]

START/END are recording-frame indexes (shot tNNN is taken at about NNN*1200).
Windows picked from screenshots are only accurate to about +/-1200 frames.
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from oam_stats import REC, frame_stats  # noqa: E402

FRAME = 357368


def pct(v, q):
    v = sorted(v)
    return v[min(len(v) - 1, int(len(v) * q))] if v else 0


print("| section | frames | OAM entries p50/p95/p99 | sprites/line p99/max | slivers/line p99/max | frames >34 slivers | frames >32 sprites | CPU busy p50/p95/p99 % | lag NMIs |")
print("|---|---|---|---|---|---|---|---|---|")
for arg in sys.argv[1:]:
    d, rng, label = arg.split(":", 2)
    a, b = map(int, rng.split("-"))
    oam = open(f"{d}/oam.oamrec", "rb").read()
    b = min(b, len(oam) // REC)
    used, spr, sliv, over_t, over_r = [], [], [], 0, 0
    for i in range(a, b):
        rec = oam[i * REC:(i + 1) * REC]
        u, s, l = frame_stats(rec[0], rec[2:])
        used.append(u)
        spr.append(max(s))
        sliv.append(max(l))
        over_t += any(x > 34 for x in l)
        over_r += any(x > 32 for x in s)
    rows = [l.split() for l in open(f"{d}/cpu.cpu") if l.strip()][a:b]
    busy = [100 * int(x) / FRAME for _, x, lag in rows if lag == "0"]
    lags = sum(lag == "1" for _, _, lag in rows)
    print(f"| {label} | {b - a} | {pct(used, .5)}/{pct(used, .95)}/{pct(used, .99)} | "
          f"{pct(spr, .99)}/{max(spr)} | {pct(sliv, .99)}/{max(sliv)} | {over_t} | {over_r} | "
          f"{pct(busy, .5):.1f}/{pct(busy, .95):.1f}/{pct(busy, .99):.1f} | {lags} |")
