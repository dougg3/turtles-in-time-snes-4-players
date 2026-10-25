#!/usr/bin/env bash
# Extension unit test (tests/extensions/ext_test.asm): assemble the test ROM twice (extended
# sprites; plus raised limits), run it on mesen-tmnt4p (tools/mesen-tmnt4p), also with
# the extensions switched off (MESEN_TMNT4P_EXT=0), and check pixels.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/build/ext_test"; mkdir -p "$out"
for c in 1 3; do
  "$root/tools/bin/asar" --fix-checksum=on -DCTRL=$c "$root/tests/extensions/ext_test.asm" "$out/ext_test$c.sfc" > /dev/null
done
printf 'wait 30\nshot s\nend\n' > "$out/cmds.txt"
run() { "$root/scripts/mesen-run.sh" "$out/cmds.txt" "$out/$1" "$out/$2" > /dev/null 2>&1; }
MESEN_DIR="${EXT_MESEN:-$root/tools/mesen-tmnt4p}" run ext ext_test1.sfc
MESEN_DIR="${EXT_MESEN:-$root/tools/mesen-tmnt4p}" run raised ext_test3.sfc
MESEN_TMNT4P_EXT=0 MESEN_DIR="${EXT_MESEN:-$root/tools/mesen-tmnt4p}" run off ext_test3.sfc
python3 - "$out" <<'PY'
import sys
from PIL import Image
out = sys.argv[1]
R, G, Y, W, B, K = (255,0,0), (0,255,0), (255,255,0), (255,255,255), (0,0,255), (0,0,0)
def px(name, x, y):
    p = Image.open(f"{out}/{name}/s.png").convert("RGB").getpixel((x, y))
    return tuple(255 if c > 200 else 0 if c < 60 else c for c in p)
# (x, y) sample points: sprites are drawn one line below their OAM Y
on = {"backdrop": ((200, 200), B), "entry 0": ((19, 20), R), "ext page+bank": ((51, 20), G),
      "ext bank": ((83, 20), Y), "ext page": ((115, 20), W), "priority lower wins": ((21, 52), R),
      "priority behind": ((26, 52), G)}
checks = {
    "ext":    dict(on, **{"line limit 32": ((245, 84), B)}),
    "raised": dict(on, **{"raised line limit": ((245, 84), R)}),
    "off":    {"backdrop": ((200, 200), K), "no ext": ((51, 20), K), "entry 0": ((19, 20), R)},
}
fail = 0
for run, cs in checks.items():
    for what, ((x, y), want) in cs.items():
        got = px(run, x, y)
        ok = got == want
        fail |= not ok
        print(f"{'ok  ' if ok else 'FAIL'} {run:6} {what}: {got}")
sys.exit(1 if fail else 0)
PY
