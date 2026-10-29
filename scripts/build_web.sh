#!/usr/bin/env bash
# Build the browser version into build/web/, ready for web/serve.py:
#   scripts/build_web.sh            the page: mesen.js/.wasm + web/site/* + the 4P BPS patches (USA, eu, au, jp)
#                                   + bots.lua (scripts/lua/play_with_bots.lua, run by web/src/bots.cpp)
#   scripts/build_web.sh bench      also the headless harness (build/web-bench/bench-native, bench-wasm.js)
# Mesen source: our fork (github.com/dougg3/mesen-tmnt4p, tools/src/mesen-tmnt4p) at the
# commit in scripts/tools.sh, exported to build/web-src; re-exported only when the commit
# changes, so rebuilds are incremental (objects in build/web-obj, rebuilt when web/Makefile
# changes). Needs the Emscripten SDK in tools/emsdk (scripts/setup.sh web).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/scripts/tools.sh"
commit=$MESEN_TMNT4P_COMMIT
emsdk="$root/tools/emsdk"
src="$root/build/web-src"
obj="$root/build/web-obj"
out="$root/build/web"
[ -x "$emsdk/upstream/emscripten/em++" ] || { echo "Emscripten SDK missing: run scripts/setup.sh web"; exit 1; }
for v in "" -eu -au -jp; do   # the four-player patch for each version of the game
  [ -f "$root/build/tmnt4-4p$v-patch.bps" ] || { echo "build/tmnt4-4p$v-patch.bps missing: run scripts/build.sh ${v#-}"; exit 1; }
done

stamp="$commit"
if [ "$(cat "$src/.stamp" 2> /dev/null)" != "$stamp" ]; then
  echo "exporting mesen-tmnt4p $commit to build/web-src"
  rm -rf "$src"
  mkdir -p "$src"
  git -C "$root/tools/src/mesen-tmnt4p" archive "$commit" | tar -x -C "$src"
  echo "$stamp" > "$src/.stamp"
fi

# objects are rebuilt from scratch when the Makefile (compiler flags) or the source changes
objstamp="$commit $(sha1sum "$root/web/Makefile" | cut -c1-12)"
if [ "$(cat "$obj/.stamp" 2> /dev/null)" != "$objstamp" ]; then
  rm -rf "$obj"
  mkdir -p "$obj"
  echo "$objstamp" > "$obj/.stamp"
fi

targets=web
[ "${1:-}" = bench ] && targets="web bench-native bench-wasm"
mkdir -p "$out"
nice -n 19 make -f "$root/web/Makefile" -j"$(( $(nproc) / 2 ))" SRC="$src" OBJ="$obj" OUT="$out" BENCH="$root/build/web-bench" EMSDK="$emsdk" NCXX="$CLANGXX" NCC="$CLANG" $targets \
  > "$root/build/web-build.log" 2>&1 || { grep -m20 -E "error" "$root/build/web-build.log"; echo "build failed: build/web-build.log"; exit 1; }
cp "$root"/web/site/* "$out/"
# the build's commit, written into session logs (app.js BUILD)
sed -i "s/^const BUILD = 'dev';/const BUILD = '$(git -C "$root" describe --always --dirty)';/" "$out/app.js"
cp "$root"/build/tmnt4-4p{,-eu,-au,-jp}-patch.bps "$out/"
cp "$root/scripts/lua/play_with_bots.lua" "$out/bots.lua"
echo "build/web ready ($(du -h "$out/mesen.wasm" | cut -f1) wasm): python3 web/serve.py"
