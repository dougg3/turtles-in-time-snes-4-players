#!/usr/bin/env bash
# 4-player bot batch: every scene, all four players AI + god mode, multitap on port 2.
#   bot4_batch.sh OUTDIR [FRAMES] [ROM]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$1"; frames="${2:-6000}"; rom="${3:-$root/build/tmnt4-4p.sfc}"
mkdir -p "$out"
export MESEN_ARGS="--Snes.Port2.Type=Multitap --Snes.Port2A.Type=SnesController --Snes.Port2B.Type=SnesController --Snes.Port2C.Type=SnesController --Snes.Port2D.Type=SnesController"
for s in 0 1 2 3 4 5 6 7 8 9; do
  python3 "$root/scripts/gen_bot4.py" $s "$frames" "$out/stage$s.txt"
  MESEN_TIMEOUT=1200 "$root/scripts/mesen-run.sh" "$out/stage$s.txt" "$out/s$s" "$rom" > "$out/s$s.out" 2>&1 &
done
wait
