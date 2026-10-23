#!/usr/bin/env python3
"""Render BG3 HUD tile layouts from a VRAM/CGRAM dump (design mockups).

  hud_mock.py VRAM CGRAM LAYOUT OUT.png [--bg SCREENSHOT] [--scale N]

LAYOUT: text file, one tilemap row per line, entries separated by spaces:
  <tile hex>[:<palette>[h][v]]   e.g. 151:1  15E:1h  .  (= transparent)
Tile numbers are BG3 tile indices (HUD tiles are $100-$1FF; char base byte $8000).
Extra tiles can be supplied with --tiles FILE (raw 2bpp, 16 bytes each, numbered from $400).
"""
import sys, argparse
from PIL import Image

ap = argparse.ArgumentParser()
ap.add_argument("vram"); ap.add_argument("cgram"); ap.add_argument("layout"); ap.add_argument("out")
ap.add_argument("--bg"); ap.add_argument("--bgy", type=int, default=0); ap.add_argument("--scale", type=int, default=4)
ap.add_argument("--tiles"); ap.add_argument("--pal", action="append", default=[],
    help="override BG3 palette: P=RRGGBB,RRGGBB,RRGGBB (colors 1-3)")
a = ap.parse_args()
v = open(a.vram, "rb").read(); c = bytearray(open(a.cgram, "rb").read())
extra = open(a.tiles, "rb").read() if a.tiles else b""
for p in a.pal:
    n, cols = p.split("=")
    for i, h in enumerate(cols.split(",")):
        r, g, b = int(h[0:2], 16) >> 3, int(h[2:4], 16) >> 3, int(h[4:6], 16) >> 3
        w = r | g << 5 | b << 10
        c[2 * (int(n) * 4 + 1 + i)] = w & 255; c[2 * (int(n) * 4 + 1 + i) + 1] = w >> 8

def color(i):
    w = c[2 * i] | c[2 * i + 1] << 8
    return ((w & 31) * 255 // 31, (w >> 5 & 31) * 255 // 31, (w >> 10 & 31) * 255 // 31)

def tile(t):
    if t >= 0x400:
        o = (t - 0x400) * 16; return extra[o:o + 16]
    o = 0x8000 + t * 16; return v[o:o + 16]

rows = [l.split() for l in open(a.layout) if l.strip() and not l.startswith("#")]
w, h = max(len(r) for r in rows) * 8, len(rows) * 8
im = Image.open(a.bg).convert("RGB").crop((0, a.bgy, w, a.bgy + h)) if a.bg else Image.new("RGB", (w, h), (60, 20, 30))
px = im.load()
for ry, row in enumerate(rows):
    for rx, e in enumerate(row):
        if e == ".": continue
        t, _, attr = e.partition(":")
        t = int(t, 16); pal = int(attr[0]) if attr and attr[0].isdigit() else 1
        hf, vf = "h" in attr, "v" in attr
        d = tile(t)
        for y in range(8):
            lo, hi = d[2 * y], d[2 * y + 1]
            for x in range(8):
                ci = (lo >> (7 - x) & 1) | (hi >> (7 - x) & 1) << 1
                if ci == 0: continue
                X = rx * 8 + (7 - x if hf else x); Y = ry * 8 + (7 - y if vf else y)
                px[X, Y] = color(pal * 4 + ci)
im.resize((w * a.scale, h * a.scale), Image.NEAREST).save(a.out)
