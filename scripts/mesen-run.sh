#!/usr/bin/env bash
# Note: Mesen's test runner has its own wall-clock limit (default 100 s); it is set
# from MESEN_TIMEOUT via --timeout, as is the outer `timeout` guard.
# Run a runner.lua command file headless: mesen-run.sh <cmds> <outdir> [rom]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cmds="$(realpath "$1")"; out="$2"; rom="${3:-$root/original/Teenage Mutant Ninja Turtles IV - Turtles in Time (USA).sfc}"
mkdir -p "$out"; out="$(realpath "$out")"
TMNT_ROOT="$root" TMNT_SCRIPT="$root/scripts/lua/runner.lua" TMNT_CMDS="$cmds" TMNT_OUT="$out" timeout "${MESEN_TIMEOUT:-600}" \
  "$root/tools/mesen/Mesen" --testRunner --timeout="${MESEN_TIMEOUT:-600}" ${MESEN_ARGS:-} "$root/scripts/lua/protect.lua" "$rom" \
  2>&1 | grep -v "Uninitialized memory read" > "$out/mesen.log" || true
cat "$out/error.txt" "$out/run.log" 2>/dev/null || true
