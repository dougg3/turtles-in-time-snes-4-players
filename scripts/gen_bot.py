#!/usr/bin/env python3
"""Generate a runner.lua command file that starts a 2P game on a given stage and
plays it with a bot while recording OAM, CPU, pool and screenshots.

  gen_bot.py STAGE FRAMES OUTFILE [--fixed] [--god]

Default bot: runner.lua's RAM-driven 'ai' (seeks enemies). --fixed uses the old
scripted walk-right/attack pattern. --god refills health/lives every frame
(measurement aid to reach bosses; runs made with it are labeled as such).

The stage is chosen by writing the stage index $82 at character select
(verified: 1 = Alleycat Blues, 2 = Sewer Surfin', 5 = Skull and Crossbones).
This is an emulator-RAM experiment only; the ROM is not modified.
"""
import sys

stage, frames, out = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
fixed = "--fixed" in sys.argv
cycle = [  # (P1 buttons, P2 buttons, frames)
    ("right,y", "right,y", 10), ("right", "right", 10), ("y", "left,y", 10),
    ("right,b", "right,b", 6), ("right", "up,right", 14), ("right,y", "down,y", 10),
]
cmds = [
    "load build/states/charsel_2p.mss", "wait 5", f"poke 82 {stage:02X} 00",
    "tap 0 b 4", "wait 10", "tap 1 b 4", "wait 200", "tap 0 start 4", "wait 60",
    "tap 0 start 4", "wait 400",
    f"bg oamrec oam {frames}", f"bg cpurec cpu {frames}", f"bg memrec pool 400 10A0 {frames}",
]
elapsed, shot = 0, 0
if not fixed:
    cmds += ["ai 0 on", "ai 1 on"] + (["god on"] if "--god" in sys.argv else [])
    while elapsed < frames:
        elapsed += 1200
        shot += 1
        cmds += ["wait 1200", f"shot t{shot:03d}", f"save t{shot:03d}.mss"]
while fixed and elapsed < frames:
    for p1, p2, n in cycle:
        cmds += [f"hold 0 {p1}", f"hold 1 {p2}", f"wait {n}"]
        elapsed += n
        if elapsed // 1200 > shot:
            shot = elapsed // 1200
            cmds += [f"shot t{shot:03d}", f"save t{shot:03d}.mss"]
cmds += ["wait 10", "end"]
open(out, "w").write("\n".join(cmds) + "\n")
