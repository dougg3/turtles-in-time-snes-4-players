#!/usr/bin/env python3
"""Extract the extension memories from a Mesen save state (mesen-tmnt4p).

  ext_state.py STATE.mss OUT_PREFIX [first_tile count palette]

Writes OUT_PREFIX_tiles.png: tiles first..first+count-1 of the extra OBJ tile memory
(16 per row, 8x scale) with extra palette `palette` (0 = palette 8), and prints a
hash per tile (blank tiles marked). Fields in the state: name, u32 length, data.
"""
import sys, zlib, struct
from PIL import Image

def fields(path):
    d = open(path, 'rb').read()
    z = zlib.decompressobj(); z.decompress(d[35:]); rest = z.unused_data   # screenshot
    for off in range(64):
        try:
            s = zlib.decompressobj().decompress(rest[off:])
            if len(s) > 10000: return s
        except Exception:
            pass
    raise SystemExit('no state block')

def get(s, name):
    i = s.find(name.encode() + b'\0')
    n = struct.unpack('<I', s[i + len(name) + 1:i + len(name) + 5])[0]
    return s[i + len(name) + 5:i + len(name) + 5 + n]

def tile_pixels(vram, t):
    b = vram[t * 32:t * 32 + 32]
    px = []
    for y in range(8):
        p0, p1, p2, p3 = b[y * 2], b[y * 2 + 1], b[16 + y * 2], b[16 + y * 2 + 1]
        px.append([((p0 >> (7 - x)) & 1) | (((p1 >> (7 - x)) & 1) << 1) | (((p2 >> (7 - x)) & 1) << 2) | (((p3 >> (7 - x)) & 1) << 3) for x in range(8)])
    return px

if __name__ == '__main__':
    s = fields(sys.argv[1])
    vram, cg = get(s, 'ppu.ppVram'), get(s, 'ppu.ppCgram')
    first, count, pal = (int(sys.argv[3], 0), int(sys.argv[4], 0), int(sys.argv[5], 0)) if len(sys.argv) > 5 else (0, 48, 0)
    cols = []
    for c in range(16):
        v = cg[(pal * 16 + c) * 2] | (cg[(pal * 16 + c) * 2 + 1] << 8)
        cols.append(((v & 31) << 3, ((v >> 5) & 31) << 3, ((v >> 10) & 31) << 3))
    rows = (count + 15) // 16
    im = Image.new('RGB', (16 * 9, rows * 9), (60, 60, 60))
    blank = []
    for k in range(count):
        t = first + k
        px = tile_pixels(vram, t)
        if all(v == 0 for r in px for v in r): blank.append(t)
        for y in range(8):
            for x in range(8):
                im.putpixel(((k % 16) * 9 + x, (k // 16) * 9 + y), cols[px[y][x]] if px[y][x] else (0, 0, 40))
    im.resize((im.width * 8, im.height * 8), Image.NEAREST).save(sys.argv[2] + '_tiles.png')
    print('blank tiles:', ' '.join('%03X' % t for t in blank))
