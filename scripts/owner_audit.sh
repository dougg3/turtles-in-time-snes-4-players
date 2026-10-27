#!/usr/bin/env bash
# Runtime two-player-assumption audit: 4P bot games (gen_bot4.py, multitap) on
# every scene with the owner probe, then owner_audit.py's report.
#   owner_audit.sh OUTDIR [ROTATIONS] [ROM]     (ROTATIONS default "0 2"; 4 runs at a time)
# OWNER_START / OWNER_FRAMES: probe window in frames after the state load (1500 / 1800).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$(mkdir -p "$1" && realpath "$1")"; rots="${2:-0 2}"; rom="${3:-$root/build/tmnt4-4p.sfc}"
python3 "$root/scripts/owner_audit.py" jmps "$rom" "$out/jmps.lua"
export OWNER_JMPS="$out/jmps.lua" TMNT_EXTRA="$root/scripts/lua/owner_probe.lua"
export OWNER_START="${OWNER_START:-1500}" OWNER_FRAMES="${OWNER_FRAMES:-1800}" MESEN_TIMEOUT=600
export MESEN_ARGS="--Snes.Port2.Type=Multitap --Snes.Port2A.Type=SnesController --Snes.Port2B.Type=SnesController --Snes.Port2C.Type=SnesController --Snes.Port2D.Type=SnesController"
for rot in $rots; do
  for s in 0 1 2 3 4 5 6 7 8 9; do
    while [ "$(jobs -r | wc -l)" -ge 4 ]; do wait -n; done
    d="$out/s${s}_r$rot"; mkdir -p "$d"
    python3 "$root/scripts/gen_bot4.py" $s $((OWNER_START + OWNER_FRAMES + 1200)) "$d/full.txt" $rot
    grep -v '^bg \|^shot \|^save \|^cdl ' "$d/full.txt" > "$d/cmds.txt"   # no recorders
    nice -n 19 "$root/scripts/mesen-run.sh" "$d/cmds.txt" "$d" "$rom" > "$d/out.txt" 2>&1 &
  done
done
wait
python3 "$root/scripts/owner_audit.py" report "$out"/s*/owner.txt
