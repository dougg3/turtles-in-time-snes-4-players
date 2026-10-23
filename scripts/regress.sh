#!/usr/bin/env bash
# Regression test: run every tests/scenarios/*.txt on a ROM and compare the
# WRAM/OAM/CGRAM hash streams with the baseline from the original ROM.
#   scripts/regress.sh baseline          # (re)create build/regress/baseline from the clean ROM
#   scripts/regress.sh [ROM]             # compare ROM (default build/tmnt4-4p.sfc) with the baseline
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${1:-}" = baseline ]; then
  rom="$root/original/Teenage Mutant Ninja Turtles IV - Turtles in Time (USA).sfc"; dest="$root/build/regress/baseline"
else
  rom="$(realpath "${1:-$root/build/tmnt4-4p.sfc}")"; dest="$root/build/regress/candidate"
fi
rm -rf "$dest"; mkdir -p "$dest"
ls "$root"/tests/scenarios/*.txt | xargs -P3 -I{} sh -c \
  'n=$(basename {} .txt); MESEN_TIMEOUT=900 "'"$root"'/scripts/mesen-run.sh" {} "'"$dest"'/$n" "'"$rom"'" > /dev/null 2>&1'
[ "${1:-}" = baseline ] && { echo "baseline written to $dest"; exit 0; }
fail=0
for f in "$root"/build/regress/baseline/*/h.hash; do
  n=$(basename "$(dirname "$f")"); c="$dest/$n/h.hash"
  if [ ! -s "$c" ]; then echo "FAIL $n: no hash output"; fail=1; continue; fi
  first=$(paste -d' ' "$f" "$c" | awk '$2!=$5 || $3!=$6 {print $1; exit}')
  if [ -n "$first" ]; then echo "FAIL $n: first difference at frame $first"; fail=1
  else echo "ok   $n ($(wc -l < "$f") samples)"; fi
done
exit $fail
