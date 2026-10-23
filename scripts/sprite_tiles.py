#!/usr/bin/env python3
"""Which sprite tiles are ever displayed, from oamrec recordings.

  sprite_tiles.py FILE.oamrec [...]

Marks every 8x8 tile covered by an on-screen sprite (16x16 = tiles t, t+1, t+16,
t+17 with 4-bit wrap inside the row, per SNES OBJ tile addressing). Tiles 0-255
are the first name table, 256-511 the second. Prints a 32x16 map per file:
'#' = used at least once, '.' = never.
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from oam_stats import REC, SIZES  # noqa: E402

union = bytearray(512)
for path in sys.argv[1:]:
    used = bytearray(512)
    data = open(path, "rb").read()
    for f in range(len(data) // REC):
        rec = data[f * REC:(f + 1) * REC]
        obsel, oam = rec[0], rec[2:]
        small, large = SIZES[obsel >> 5]
        for i in range(128):
            x, y, tile, attr = oam[i * 4:i * 4 + 4]
            hi = (oam[512 + i // 4] >> ((i % 4) * 2)) & 3
            w, h = large if hi & 2 else small
            if hi & 1:
                x -= 256
            if y == 0xF0 or x <= -w or x >= 256 or (224 <= y < 256 - h):
                continue
            base = tile | ((attr & 1) << 8)
            for ty in range(h // 8):
                for tx in range(w // 8):
                    t = (base & 0x100) | ((((base >> 4) + ty) & 0xF) << 4) | (((base & 0xF) + tx) & 0xF)
                    used[t] = 1
    for i, v in enumerate(used):
        union[i] |= v
    print(f"{path}: {sum(used)}/512 tiles used")
    for row in range(32):
        print("   " + "".join("#" if used[row * 16 + c] else "." for c in range(16)) +
              (f"  tiles ${row * 16:03X}" if row % 4 == 0 else ""))
print(f"union: {sum(union)}/512")
