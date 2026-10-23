#!/usr/bin/env python3
"""Generate a 4-player bot run (needs the 4P patch and Mesen Port2 = Multitap).

  gen_bot4.py STAGE FRAMES OUTFILE

Like gen_bot.py, but sets 4-player mode at character select (!PlayerMode $1A78 = 4, see patches/ram.asm;
P3 = Don $D4 = 6, P4 = Raph $D8 = 8; P1 Leo / P2 Mike) and runs the AI bot and
god mode for all four players.
"""
import sys

stage, frames, out = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
cmds = [
    "load build/states/charsel_2p.mss", "wait 5", f"poke 82 {stage:02X} 00",
    "poke 1A78 04", "poke D4 06 00", "poke D8 08 00",
    "tap 0 b 4", "wait 10", "tap 1 b 4", "wait 200", "tap 0 start 4", "wait 60",
    "tap 0 start 4", "wait 900",
    f"bg oamrec oam {frames}", f"bg cpurec cpu {frames}", f"bg memrec pool 400 10A0 {frames}",
    "ai 0 on", "ai 1 on", "ai 2 on", "ai 3 on", "god on",
]
shot, elapsed = 0, 0
while elapsed < frames:
    elapsed += 1200
    shot += 1
    cmds += ["wait 1200", f"shot t{shot:03d}", f"save t{shot:03d}.mss"]
cmds += ["wait 10", "end"]
open(out, "w").write("\n".join(cmds) + "\n")
