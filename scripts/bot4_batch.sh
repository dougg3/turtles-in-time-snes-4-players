#!/usr/bin/env bash
# 4-player bot batch: every scene, all four players AI + god mode, multitap on port 2.
#   bot4_batch.sh OUTDIR [FRAMES] [ROM]     (BOT_ROT=0-3: turtle rotation, gen_bot4.py)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$1"; frames="${2:-6000}"; rom="${3:-$root/build/tmnt4-4p.sfc}"
mkdir -p "$out"
export MESEN_ARGS="--Snes.Port2.Type=Multitap --Snes.Port2A.Type=SnesController --Snes.Port2B.Type=SnesController --Snes.Port2C.Type=SnesController --Snes.Port2D.Type=SnesController"
for s in 0 1 2 3 4 5 6 7 8 9; do
  python3 "$root/scripts/gen_bot4.py" $s "$frames" "$out/stage$s.txt" "${BOT_ROT:-0}"
  MESEN_TIMEOUT=1200 "$root/scripts/mesen-run.sh" "$out/stage$s.txt" "$out/s$s" "$rom" > "$out/s$s.out" 2>&1 &
done
wait
# Landed attacks per player (attack objects $05C0/$06A0/$1530/$1640 as Y at $03:839D).
# Every player must land hits in every scene: a zero means that player cannot attack.
python3 - "$out" <<'PY'
import sys, os
out = sys.argv[1]; bad = 0
objs = {"Y=05C0": "P1", "Y=06A0": "P2", "Y=1530": "P3", "Y=1640": "P4"}
for s in range(10):
    f = os.path.join(out, f"s{s}", "hits.hooks")
    n = dict.fromkeys(objs.values(), 0)
    if os.path.exists(f):
        for line in open(f):
            for t in line.split():
                if t in objs: n[objs[t]] += 1
    zero = [p for p, c in n.items() if c == 0]
    bad += bool(zero)
    print(f"scene {s + 1}: hits " + " ".join(f"{p} {c}" for p, c in n.items()) + ("   NO HITS: " + ", ".join(zero) if zero else ""))
sys.exit(1 if bad else 0)
PY
