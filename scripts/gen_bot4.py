#!/usr/bin/env python3
"""Generate a 4-player bot run (needs the 4P patch and Mesen Port2 = Multitap).

  gen_bot4.py STAGE FRAMES OUTFILE [ROT]

Like gen_bot.py, but P3/P4 join at turtle select by pressing START on multitap pads
3/4 (patches/select4.asm) and everyone confirms the turtle the cursor starts on
(P1 Leo, P2 Mike, P3 Don, P4 Raph); runs the AI bot and god mode for all four. Logs every landed hit (hits.hooks)
for scripts/bot4_batch.sh's per-player report. ROT (0-3): before confirming,
every player moves the cursor right ROT times, so each player slot gets a
different turtle (all four cursors move together and stay distinct).
"""
import sys

stage, frames, out = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
rot = int(sys.argv[4]) if len(sys.argv) > 4 else 0
move = []
for _ in range(rot):
    move += ["tap 0 right 4", "wait 10", "tap 1 right 4", "wait 10",
             "mtap 1 right", "wait 4", "mtap 1 -", "wait 10", "mtap 2 right", "wait 4", "mtap 2 -", "wait 10"]
cmds = [
    "load build/states/charsel_2p.mss", "wait 5", f"poke 82 {stage:02X} 00",
    "wait 10", "mtap 1 start", "wait 4", "mtap 1 -", "wait 10",
    "mtap 2 start", "wait 4", "mtap 2 -", "wait 10",
    *move,
    "tap 0 b 4", "wait 10", "tap 1 b 4", "wait 10",
    "mtap 1 b", "wait 4", "mtap 1 -", "wait 10", "mtap 2 b", "wait 4", "mtap 2 -",
    "wait 200", "tap 0 start 4", "wait 60",
    "tap 0 start 4", "wait 900",
    f"bg oamrec oam {frames}", f"bg cpurec cpu {frames}", f"bg memrec pool 400 10A0 {frames}",
    f"bg hooks hits {frames} 03839D",  # Y = attack object when a player's attack lands
    "ai 0 on", "ai 1 on", "ai 2 on", "ai 3 on", "god on",
]
shot, elapsed = 0, 0
while elapsed < frames:
    elapsed += 1200
    shot += 1
    cmds += ["wait 1200", f"shot t{shot:03d}", f"save t{shot:03d}.mss"]
cmds += ["wait 10", "cdl cov", "end"]  # cov.cdl: code executed (find_2p_refs2.py)
open(out, "w").write("\n".join(cmds) + "\n")
