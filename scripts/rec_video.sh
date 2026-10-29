#!/usr/bin/env bash
# Video of a stretch of a play_with_bots recording, every frame numbered (exact
# replay of the recorded input, scripts/lua/replay_rec.lua). Needs pads.txt
# (recordings since 2026-10-24) for an exact replay.
#   rec_video.sh RECDIR FIRST LAST [OUT.mp4]
#     RECDIR  build/play/rec/<date-time> (or build/play/rec/latest)
#     FIRST LAST  frame numbers (as in events.log; a MARK line gives the frame)
#     OUT     default RECDIR/video_FIRST-LAST.mp4
# REC_ROM: the ROM the session was played with (default build/tmnt4-4p.sfc; the
# replay is only exact with the same ROM: events.log names it since 2026-10-24 13:30)
# Also writes OUT's frames as PNG next to it (OUT minus .mp4, a directory).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
rec="$(realpath "$1")"; first="$2"; last="$3"
out="${4:-$rec/video_${first}-${last}.mp4}"
# the latest state at or before FIRST
base=$(ls "$rec/states" | grep -E '^[0-9]{8}\.mss$' | sed 's/\.mss//' | awk -v f="$first" '$1+0 <= f+0' | sort -n | tail -1)
[ -n "$base" ] || { echo "no state before frame $first" >&2; exit 1; }
base=$((10#$base))
work="$(mktemp -d)"
mkdir -p "$work/run/frames"
printf "wait %d\nend\n" $((last - base + 400)) > "$work/cmds.txt"
REPLAY_DIR="$rec" REPLAY_FRAME="$base" REPLAY_SHOTS="$first $last" \
  TMNT_EXTRA="$root/scripts/lua/replay_rec.lua" MESEN_DIR="$root/tools/mesen-tmnt4p" \
  MESEN_TIMEOUT=1800 MESEN_ARGS="--Snes.Port2.Type=Multitap --Snes.Port2A.Type=SnesController --Snes.Port2B.Type=SnesController --Snes.Port2C.Type=SnesController --Snes.Port2D.Type=SnesController" \
  "$root/scripts/mesen-run.sh" "$work/cmds.txt" "$work/run" "${REC_ROM:-$root/build/tmnt4-4p.sfc}" > /dev/null || true
pngdir="${out%.mp4}"
rm -rf "$pngdir"; mkdir -p "$pngdir"
python3 - "$work/run/frames" "$pngdir" <<'PY'
import sys, os
from PIL import Image, ImageDraw, ImageFont
src, dst = sys.argv[1], sys.argv[2]
font = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf', 22)
names = sorted(os.listdir(src))
for i, n in enumerate(names):
    frame = int(n[:-4])
    im = Image.frombytes('RGB', (256, 239), open(os.path.join(src, n), 'rb').read()).crop((0, 7, 256, 231))   # buffer: 7 overscan lines above the picture
    big = Image.new('RGB', (768, 672 + 34), (0, 0, 0))
    big.paste(im.resize((768, 672), Image.NEAREST), (0, 34))
    ImageDraw.Draw(big).text((8, 4), 'frame %d' % frame, font=font, fill=(255, 255, 0))
    big.save(os.path.join(dst, 'f%08d.png' % frame))
print(len(names), 'frames')
PY
ffmpeg -loglevel error -y -framerate 60 -pattern_type glob -i "$pngdir/f*.png" -c:v libx264 -pix_fmt yuv420p -crf 18 "$out"
rm -rf "$work"
echo "$out"
