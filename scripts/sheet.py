#!/usr/bin/env python3
"""Tile screenshots into a contact sheet: sheet.py out.png in1.png in2.png ..."""
import sys
from PIL import Image, ImageDraw

ims = [Image.open(p).convert("RGB") for p in sys.argv[2:]]
w, h = ims[0].size
cols = min(4, len(ims))
rows = (len(ims) + cols - 1) // cols
sheet = Image.new("RGB", (cols * (w + 4), rows * (h + 14)), "white")
draw = ImageDraw.Draw(sheet)
for i, (im, path) in enumerate(zip(ims, sys.argv[2:])):
    x, y = (i % cols) * (w + 4), (i // cols) * (h + 14)
    sheet.paste(im, (x, y + 12))
    draw.text((x + 2, y), path.rsplit("/", 1)[-1], fill="black")
sheet.save(sys.argv[1])
