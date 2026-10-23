#!/usr/bin/env python3
"""Summarize runner.lua 'cpurec' files: cpu_stats.py FILE.cpu [...]"""
import sys

FRAME_CLOCKS = 357368  # NTSC: 1364 x 262 master clocks

for path in sys.argv[1:]:
    rows = [tuple(map(int, l.split())) for l in open(path) if l.strip()]
    busy = sorted(b for _, b, lag in rows if not lag)
    lags = sum(lag for _, _, lag in rows)
    if not busy:
        print(f"{path}: no complete NMIs")
        continue
    pct = lambda v: 100 * v / FRAME_CLOCKS
    print(f"{path}: {len(rows)} NMIs, lag NMIs {lags}; busy % of frame: "
          f"median {pct(busy[len(busy) // 2]):.1f}, p95 {pct(busy[int(len(busy) * .95)]):.1f}, "
          f"max {pct(busy[-1]):.1f}")
