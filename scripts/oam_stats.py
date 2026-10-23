#!/usr/bin/env python3
"""Per-scanline sprite statistics from runner.lua 'oamrec' recordings.

  oam_stats.py FILE.oamrec [--per-frame]

Rules (SNESdev wiki "Sprites", fullsnes "PPU OAM load"):
  - a sprite is in range on a line if the line is within its height (Y wraps at 256)
    and it is at least partly on screen horizontally, or X == -256 (PPU quirk)
  - more than 32 in-range sprites on a line -> range over (highest OAM indexes dropped)
  - more than 34 8-pixel slivers on a line -> time over; only on-screen slivers count
    except at X == -256 where all slivers count
"""
import sys

REC = 546
# OBSEL bits 5-7 -> ((small w,h), (large w,h))
SIZES = {
    0: ((8, 8), (16, 16)), 1: ((8, 8), (32, 32)), 2: ((8, 8), (64, 64)),
    3: ((16, 16), (32, 32)), 4: ((16, 16), (64, 64)), 5: ((32, 32), (64, 64)),
    6: ((16, 32), (32, 64)), 7: ((16, 32), (32, 32)),
}
VISIBLE_LINES = 224


def sprites(obsel, oam):
    small, large = SIZES[obsel >> 5]
    for i in range(128):
        x, y = oam[i * 4], oam[i * 4 + 1]
        hi = (oam[512 + i // 4] >> ((i % 4) * 2)) & 3
        if hi & 1:
            x -= 256
        w, h = large if hi & 2 else small
        yield i, x, y, w, h


def frame_stats(obsel, oam):
    per_line_spr = [0] * VISIBLE_LINES
    per_line_sliv = [0] * VISIBLE_LINES
    used = 0
    for i, x, y, w, h in sprites(obsel, oam):
        onscreen_x = x > -w and x < 256
        if not onscreen_x and x != -256:
            continue
        visible_any = False
        for dy in range(h):
            line = (y + dy) & 0xFF
            if line >= VISIBLE_LINES:
                continue
            visible_any = True
            per_line_spr[line] += 1
            if x == -256:
                per_line_sliv[line] += w // 8
            else:
                per_line_sliv[line] += sum(1 for sx in range(x, x + w, 8) if -8 < sx < 256)
        used += visible_any
    return used, per_line_spr, per_line_sliv


def main():
    data = open(sys.argv[1], "rb").read()
    per_frame = "--per-frame" in sys.argv
    n = len(data) // REC
    worst = dict(used=0, spr=0, sliv=0, range_lines=0, time_lines=0)
    frames_over = 0
    ppu_frames = 0
    for f in range(n):
        rec = data[f * REC:(f + 1) * REC]
        used, spr, sliv = frame_stats(rec[0], rec[2:])
        ppu_time, ppu_range = bool(rec[1] & 0x80), bool(rec[1] & 0x40)
        ppu_frames += ppu_time or ppu_range
        rl = sum(1 for v in spr if v > 32)
        tl = sum(1 for v in sliv if v > 34)
        frames_over += bool(rl or tl)
        worst["used"] = max(worst["used"], used)
        worst["spr"] = max(worst["spr"], max(spr))
        worst["sliv"] = max(worst["sliv"], max(sliv))
        worst["range_lines"] = max(worst["range_lines"], rl)
        worst["time_lines"] = max(worst["time_lines"], tl)
        if per_frame:
            print(f"frame {f:4d} obsel={rec[0]:02X} visible_sprites={used:3d} "
                  f"max_spr/line={max(spr):2d} max_slivers/line={max(sliv):2d} "
                  f"lines>32spr={rl:3d} lines>34sliv={tl:3d} ppu_time_over={int(ppu_time)} ppu_range_over={int(ppu_range)}")
    print(f"{n} frames: max visible sprites {worst['used']}/128, "
          f"max sprites/line {worst['spr']}/32, max slivers/line {worst['sliv']}/34, "
          f"worst-frame lines over sprite limit {worst['range_lines']}, "
          f"over sliver limit {worst['time_lines']}, frames with any overflow {frames_over} "
          f"(PPU $213E flags set in {ppu_frames} frames)")


if __name__ == "__main__":
    main()
