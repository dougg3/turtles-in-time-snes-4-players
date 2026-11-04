#!/usr/bin/env bash
# Video of a play_with_bots session, made afterwards from its movie (session.mmo): an
# exact replay of the whole session (or a stretch), so --video isn't needed while playing.
#   make_video.sh RECDIR [FROM [TO]] [--out OUT.mp4]
#     RECDIR  build/play/rec/<date-time> (or build/play/rec/latest)
#     FROM TO session frames (as in events.log, e.g. a MARK line); default: all
#     OUT     default RECDIR/video.mp4, or RECDIR/video_FROM-TO.mp4
# The replay uses the ROM saved with the session (RECDIR/rom.sfc) and runs headless in
# mesen-tmnt4p (tools/mesen-tmnt4p; its settings are not changed). MP4 as --video:
# 3x with sharp pixels, H.264 + AAC (needs ffmpeg).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
usage() { echo "usage: $0 RECDIR [FROM [TO]] [--out OUT.mp4]" >&2; exit 1; }
[ $# -ge 1 ] || usage
rec="$(realpath "$1")"; shift
from=""; to=""; out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) shift; out="${1:-}" ;;
    *) if [ -z "$from" ]; then from="$1"; elif [ -z "$to" ]; then to="$1"; else usage; fi ;;
  esac
  shift
done
[ -s "$rec/session.mmo" ] || { echo "no session.mmo in $rec (Mesen writes it when it closes)" >&2; exit 1; }
command -v ffmpeg > /dev/null || { echo "needs ffmpeg" >&2; exit 1; }
rom="$rec/rom.sfc"
[ -f "$rom" ] || { echo "no rom.sfc in $rec: using build/tmnt4-4p.sfc (exact only if unchanged)" >&2; rom="$root/build/tmnt4-4p.sfc"; }
start=$(cat "$rec/movie.txt" 2>/dev/null || echo 0)     # session frame of the movie's first frame
first=""; last=""
if [ -n "$from" ]; then first=$((from > start ? from - start : 0)); fi
if [ -n "$to" ]; then last=$((to - start)); fi
if [ -z "$out" ]; then
  if [ -n "$from" ]; then out="$rec/video_${from}-${to:-end}.mp4"; else out="$rec/video.mp4"; fi
fi
work="$(mktemp -d)"
echo "replaying $rec/session.mmo ..."
TMNT_SCRIPT="$root/scripts/lua/movie_video.lua" TMNT_OUT="$work" MOVIE="$rec/session.mmo" \
  VIDEO_OUT="$work/video.avi" VIDEO_FIRST="$first" VIDEO_LAST="$last" timeout 14400 \
  "$root/tools/mesen-tmnt4p/mesen-tmnt4p" --testRunner --timeout=14400 --donotsavesettings \
  "$root/scripts/lua/protect.lua" "$rom" > "$work/mesen.log" 2>&1 || true
cat "$work/movie_video.txt" "$work/error.txt" 2>/dev/null || true
[ -s "$work/video.avi" ] || { echo "no video was recorded (log: $work)" >&2; exit 1; }
echo "making $out ..."
ffmpeg -loglevel error -y -i "$work/video.avi" -vf "scale=-2:ih*3:flags=neighbor" \
  -c:v libx264 -preset medium -crf 23 -tune animation -g 600 -pix_fmt yuv420p -c:a aac -b:a 192k \
  -movflags +faststart "$out"
rm -r "$work"
echo "video: $out"
