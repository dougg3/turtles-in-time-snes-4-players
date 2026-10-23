#!/usr/bin/env python3
"""Summarize runner.lua 'dmarec' logs: dma_stats.py FILE.dma

Groups general-DMA transfers by caller and B-bus target, and reports bytes per
frame. B-bus $18/$19 = VRAM data, $04 = OAM, $22 = CGRAM.
"""
import sys
from collections import defaultdict

TARGET = {0x18: "VRAM", 0x19: "VRAM(hi)", 0x04: "OAM", 0x22: "CGRAM", 0x80: "WRAM"}
rows = [l.split() for l in open(sys.argv[1]) if l.strip()]
frames = sorted({int(r[0]) for r in rows})
per_frame = defaultdict(int)
per_frame_vram = defaultdict(int)
groups = defaultdict(lambda: {"n": 0, "bytes": 0, "srcs": set(), "dsts": set(), "vblank": set()})
for f, pc, ch, ctrl, bbus, src, size, vmadd, vb in rows:
    t = TARGET.get(int(bbus, 16), f"B${bbus}")
    g = groups[(pc, t)]
    g["n"] += 1
    g["bytes"] += int(size)
    g["srcs"].add(src)
    g["vblank"].add(vb)
    if t.startswith("VRAM"):
        g["dsts"].add(vmadd)
        per_frame_vram[int(f)] += int(size)
    per_frame[int(f)] += int(size)
n = frames[-1] - frames[0] + 1
print(f"{len(rows)} transfers over {n} frames")
for (pc, t), g in sorted(groups.items(), key=lambda kv: -kv[1]["bytes"]):
    print(f"  caller {pc} -> {t:8s}: {g['n']:4d} transfers, {g['bytes'] / n:7.0f} bytes/frame avg, "
          f"{len(g['srcs'])} distinct sources, {len(g['dsts'])} distinct VRAM dests, in vblank {sorted(g['vblank'])}")
vals = [per_frame_vram.get(f, 0) for f in range(frames[0], frames[-1] + 1)]
tot = [per_frame.get(f, 0) for f in range(frames[0], frames[-1] + 1)]
vals.sort(); tot.sort()
print(f"VRAM bytes/frame: median {vals[len(vals) // 2]}, p95 {vals[int(len(vals) * .95)]}, max {vals[-1]}")
print(f"all DMA bytes/frame: median {tot[len(tot) // 2]}, p95 {tot[int(len(tot) * .95)]}, max {tot[-1]}")
