#!/usr/bin/env bash
# Regression test: run every tests/scenarios/*.txt on a ROM and compare the
# WRAM/OAM/CGRAM hash streams with the baseline from the original ROM.
#   scripts/regress.sh baseline          # (re)create build/regress/baseline from the clean ROM
#   scripts/regress.sh [ROM]             # compare ROM (default build/tmnt4-4p.sfc) with the baseline
# REGRESS_ONLY=<name> runs (and, with baseline, re-records) that one scenario only.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# the scenarios start from save states of the clean ROM: made once
[ -f "$root/build/regress/states/scene1_1p.mss" ] || "$root/scripts/make_regress_states.sh" > /dev/null
if [ "${1:-}" = baseline ]; then
  rom="$root/original/Teenage Mutant Ninja Turtles IV - Turtles in Time (USA).sfc"; dest="$root/build/regress/baseline"
else
  rom="$(realpath "${1:-$root/build/tmnt4-4p.sfc}")"; dest="$root/build/regress/candidate"
fi
only="${REGRESS_ONLY:-*}"
if [ -n "${REGRESS_ONLY:-}" ]; then rm -rf "$dest/$REGRESS_ONLY"; else rm -rf "$dest"; fi
mkdir -p "$dest"
# WRAM ranges that patches deliberately repurpose (input slots, new variables);
# excluded from the WRAM hash for both baseline and candidate.
export TMNT_HASH_EXCLUDE="$(tr -d ' \n' < "$root/tests/hash_exclude.txt")"
# Extra invisible scanlines before NMI (more CPU per frame) for BOTH baseline and
# candidate: patches change CPU time, and in stages that run at the CPU limit that
# alone changes which frames lag and therefore the game's course.
# With spare CPU, comparisons stay strict. REGRESS_REALTIME=1 disables this.
if [ "${REGRESS_REALTIME:-0}" != 1 ]; then export MESEN_ARGS="--Snes.PpuExtraScanlinesBeforeNmi=400"; fi
# Relocated state (orig:new:len) is read from its new address in candidate runs only.
if [ "${1:-}" != baseline ]; then export TMNT_HASH_MAP="$(tr -d ' \n' < "$root/tests/hash_map.txt")"; fi
ls "$root"/tests/scenarios/$only.txt | xargs -P3 -I{} sh -c \
  'n=$(basename {} .txt); MESEN_TIMEOUT=900 "'"$root"'/scripts/mesen-run.sh" {} "'"$dest"'/$n" "'"$rom"'" > /dev/null 2>&1'
[ "${1:-}" = baseline ] && { echo "baseline written to $dest"; exit 0; }
# Boot smoke test (not frame-compared, see tests/scenarios.boot/README.md):
# power-on through menus must reach Scene 1 gameplay with both player objects active.
smoke="$dest/boot_smoke"; mkdir -p "$smoke"
sed -e '/^bg framehash/d' -e '/^rngpin/d' -e 's/^wait 3000$/wait 300\npeek 414 2\npeek 484 2/' \
  "$root/tests/scenarios.boot/scene1.txt" > "$smoke/cmds.txt"
MESEN_TIMEOUT=300 "$root/scripts/mesen-run.sh" "$smoke/cmds.txt" "$smoke" "$rom" > /dev/null 2>&1 || true
if grep -q "peek 00414: 00 00" "$smoke/run.log" || grep -q "peek 00484: 00 00" "$smoke/run.log" || ! grep -q "peek 00484" "$smoke/run.log"; then
  echo "FAIL boot smoke test: players not active after boot/menus/intro"; smoke_fail=1
else
  echo "ok   boot smoke test ($(grep 'peek 00414' "$smoke/run.log"))"; smoke_fail=0
fi
fail=0
for f in "$root"/build/regress/baseline/$only/h.hash; do
  n=$(basename "$(dirname "$f")"); c="$dest/$n/h.hash"
  if [ ! -s "$c" ]; then echo "FAIL $n: no hash output"; fail=1; continue; fi
  # (no early exit in awk: with pipefail, SIGPIPE on paste would abort the script)
  stats=$(paste -d' ' "$f" "$c" | awk '{n++} ($2!=$5 || $3!=$6) {d++; if (!first) first=$1 " (" ($2!=$5 ? "OAM/CGRAM" : "") ($3!=$6 ? " WRAM" : "") ")"; last=n}
    END {printf "%d %d %d %s", n, d+0, n-last, first}')
  read -r total ndiff tailok firstdiff <<< "$stats"
  # Lag-frame comparison: several stages run at the CPU limit, so a patch
  # that changes CPU time can change which frames lag, after which the game
  # legitimately plays out differently. Such runs are reported as TIMING.
  lagdiff=$(paste -d' ' "$(dirname "$f")/lag.cpu" "$(dirname "$c")/lag.cpu" 2>/dev/null | \
    awk '!x && $3!=$6 {print NR; x=1}')
  start=$(head -1 "$f" | awk '{print $1}')
  if [ "$ndiff" -eq 0 ]; then echo "ok     $n ($total samples)"
  elif [ -n "$lagdiff" ] && [ "${firstdiff%% *}" -ge $(( start + lagdiff - 8 )) ]; then
    echo "TIMING $n: lag pattern changes at frame ~$(( start + lagdiff )); $ndiff/$total samples differ after it (first $firstdiff)"
  else echo "FAIL   $n: $ndiff/$total samples differ, first at frame $firstdiff, last $tailok samples identical"; fail=1; fi
done
exit $(( fail | smoke_fail ))
