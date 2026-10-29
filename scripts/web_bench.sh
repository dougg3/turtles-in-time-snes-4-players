#!/usr/bin/env bash
# Speed and determinism check of the browser build:
#   scripts/web_bench.sh [FRAMES]      (default 1200 frames per state)
# Makes fresh 4P save states for the current build/tmnt4-4p.sfc (four bots in Scene 1, headless
# mesen-tmnt4p, web/bench-state.cmds), then runs the same frames natively (clang) and as WASM
# (Node, same engine as Chrome) and checks that both end with the same WRAM.
# Needs `scripts/build_web.sh bench`. Output in build/web-bench/ (small).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
frames="${1:-1200}"
out="$root/build/web-bench"
bin="$root/build/web-bench"
[ -x "$bin/bench-native" ] && [ -f "$bin/bench-wasm.js" ] || { echo "run scripts/build_web.sh bench first"; exit 1; }
node="$(ls "$root"/tools/emsdk/node/*/bin/node | head -1)"
mkdir -p "$out"
cp "$root/build/tmnt4-4p.sfc" "$out/rom.sfc"
rm -f "$out"/run/s*.mss
MESEN_DIR="$root/tools/mesen-tmnt4p" MESEN_TIMEOUT=600 \
MESEN_ARGS="--Snes.Port2.Type=Multitap --Snes.Port2A.Type=SnesController --Snes.Port2B.Type=SnesController --Snes.Port2C.Type=SnesController --Snes.Port2D.Type=SnesController" \
  nice -n 19 "$root/scripts/mesen-run.sh" "$root/web/bench-state.cmds" "$out/run" "$out/rom.sfc" > "$out/states.log"
ls "$out"/run/s*.mss > /dev/null 2>&1 || { echo "no save states made: see $out/states.log"; exit 1; }
fail=0
for s in "$out"/run/s*.mss; do
  n="$(nice -n 19 "$bin/bench-native" "$out/rom.sfc" "$s" "$frames" | grep frames=)"
  w="$(timeout 300 nice -n 19 "$node" "$bin/bench-wasm.js" "$out/rom.sfc" "$s" "$frames" | grep frames=)"
  echo "$(basename "$s") native: $n"
  echo "$(basename "$s") wasm:   $w"
  [ "${n##*wram=}" = "${w##*wram=}" ] || { echo "  WRAM DIFFERS between native and wasm"; fail=1; }
done
[ $fail = 0 ] && echo "native and wasm: identical WRAM on every state"
exit $fail
