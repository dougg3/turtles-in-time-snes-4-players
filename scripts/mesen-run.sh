#!/usr/bin/env bash
# Note: Mesen's test runner has its own wall-clock limit (default 100 s); it is set
# from MESEN_TIMEOUT via --timeout, as is the outer `timeout` guard.
# MESEN_DIR selects another Mesen build (default tools/mesen-tmnt4p, from scripts/setup.sh).
# Run a runner.lua command file headless: mesen-run.sh <cmds> <outdir> [rom]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cmds="$(realpath "$1")"; out="$2"; rom="${3:-$root/original/Teenage Mutant Ninja Turtles IV - Turtles in Time (USA).sfc}"
mkdir -p "$out"; out="$(realpath "$out")"
# Mesen saves command-line settings to its settings.json, so a multitap run would
# leave the multitap plugged in for later runs (it did). Always state the
# ports; MESEN_ARGS with its own port settings replaces these.
ports="--Snes.Port1.Type=SnesController --Snes.Port2.Type=SnesController"
for p in 2A 2B 2C 2D; do ports="$ports --Snes.Port$p.Type=None"; done
case "${MESEN_ARGS:-}" in *Port2*) ports="" ;; esac
dir="${MESEN_DIR:-$root/tools/mesen-tmnt4p}"
exe="$dir/mesen-tmnt4p"; [ -x "$exe" ] || exe="$dir/Mesen"   # upstream Mesen's name
TMNT_ROOT="$root" TMNT_SCRIPT="$root/scripts/lua/runner.lua" TMNT_CMDS="$cmds" TMNT_OUT="$out" timeout "${MESEN_TIMEOUT:-600}" \
  "$exe" --testRunner --timeout="${MESEN_TIMEOUT:-600}" $ports ${MESEN_ARGS:-} "$root/scripts/lua/protect.lua" "$rom" \
  2>&1 | grep -v "Uninitialized memory read" > "$out/mesen.log" || true
cat "$out/error.txt" "$out/run.log" 2>/dev/null || true
