#!/usr/bin/env python3
"""Convert runner.lua rawshot files (.rgb: "W H\\n" + RGB bytes) to PNG: rgb2png.py FILE..."""
import sys
from PIL import Image
for path in sys.argv[1:]:
    data = open(path, "rb").read()
    head, _, pixels = data.partition(b"\n")
    w, h = map(int, head.split())
    Image.frombytes("RGB", (w, h), pixels[:w * h * 3]).save(path[:-4] + ".png")
