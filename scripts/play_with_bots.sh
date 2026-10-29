#!/usr/bin/env bash
# Play the 4-player build as one player with bots as the others (testing aid; the
# ROM is not changed). Starts mesen-tmnt4p with scripts/lua/play_with_bots.lua.
#   play_with_bots.sh PLAYER [--players N] [--god] [ROM]
#     PLAYER       your player, 1-4
#     --players N  players taking part, 2-4 (default 4): P1..PN; the others stay out
#     --god        keep the bots' health up
#     --no-record  don't record the session (default: build/play/rec/<date-time>/, see
#                  the recorder notes in scripts/lua/play_with_bots.lua)
#     --state FILE start from this save state (e.g. a recording's
#                  build/play/rec/<date-time>/states/<frame>.mss) instead of power-on
#     --video      also record a video with sound (Mesen's video recorder, started by
#                  the script) and turn it into build/play/video/<date-time>.mp4 when
#                  Mesen is closed (3x size, sharp pixels; needs ffmpeg)
#     ROM     default build/tmnt4-4p.sfc
# Mesen settings needed once: Port 2 = Multitap, sub-ports A-C =
# SNES controller, your pad mapped to your player's port (or to all four).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
human="${1:-}"
usage() { echo "usage: $0 PLAYER(1-4) [--players N(2-4)] [--god] [--no-record] [--video] [--state FILE] [ROM]" >&2; exit 1; }
case "$human" in 1|2|3|4) ;; *) usage ;; esac
shift
god=false
record=true
video=false
players=4
state=nil
rom="$root/build/tmnt4-4p.sfc"
while [ $# -gt 0 ]; do
  case "$1" in
    --god) god=true ;;
    --no-record) record=false ;;
    --video) video=true ;;
    --players) shift; players="${1:-}" ;;
    --state) shift; [ -f "${1:-}" ] || { echo "no such state: ${1:-}" >&2; exit 1; }; state="\"$(realpath "$1")\"" ;;
    *) rom="$(realpath "$1")" ;;
  esac
  shift
done
case "$players" in 2|3|4) ;; *) usage ;; esac
[ "$human" -le "$players" ] || { echo "you are P$human but only $players players take part" >&2; exit 1; }
mkdir -p "$root/build/play"
rec=nil
if $record; then
  dir="$root/build/play/rec/$(date +%Y-%m-%d_%H%M%S)"
  mkdir -p "$dir/states"
  ln -sfn "$dir" "$root/build/play/rec/latest"
  cp "$rom" "$dir/rom.sfc"        # the movie replays exactly only on this ROM (make_video.sh)
  rec="\"$dir\""
  echo "recording to $dir"
fi
avi=nil
if $video; then
  command -v ffmpeg > /dev/null || { echo "--video needs ffmpeg" >&2; exit 1; }
  mkdir -p "$root/build/play/video"
  name="$root/build/play/video/$(date +%Y-%m-%d_%H%M%S)"
  avi="\"$name.avi\""
  echo "video: $name.mp4 (made when Mesen is closed)"
fi
script="$root/build/play/bots_p$human.lua"
sed -e "s/^local HUMAN = .*/local HUMAN = $human/" -e "s/^local BOT_GOD = .*/local BOT_GOD = $god/" \
  -e "s/^local PLAYERS = .*/local PLAYERS = $players/" \
  -e "s|^local REC_DIR = .*|local REC_DIR = $rec|" \
  -e "s|^local VIDEO = .*|local VIDEO = $avi|" \
  -e "s|^local START_STATE = .*|local START_STATE = $state|" \
  "$root/scripts/lua/play_with_bots.lua" > "$script"
if ! $video; then
  exec "$root/tools/mesen-tmnt4p/Mesen" "$rom" "$script"
fi
"$root/tools/mesen-tmnt4p/Mesen" "$rom" "$script" || true
# AVI (Mesen's ZMBV, game picture and sound) -> MP4: 3x with sharp pixels (sites
# blur small videos), H.264 + AAC, playable everywhere. medium/crf 23 + tune
# animation + 10 s keyframes, chosen for speed (30 s Scene 4 clip): 3.5 s to
# encode, 21 MB per minute, SSIM vs the lossless picture 0.992 (veryslow/crf 20:
# 14 s, 19 MB, 0.996; slow/crf 18 without tuning: 5 s, 29 MB, 0.996; AV1 is
# slower for the same size)
if [ -s "$name.avi" ]; then
  echo "making $name.mp4 ..."
  if ffmpeg -loglevel error -y -i "$name.avi" -vf "scale=-2:ih*3:flags=neighbor" \
       -c:v libx264 -preset medium -crf 23 -tune animation -g 600 -pix_fmt yuv420p -c:a aac -b:a 192k \
       -movflags +faststart "$name.mp4"; then
    rm -f "$name.avi"
    echo "video: $name.mp4"
  else
    echo "ffmpeg failed; the recording is kept as $name.avi" >&2
  fi
else
  echo "no video was recorded (mesen-tmnt4p must be built with startVideoRecording:" \
       "scripts/setup.sh)" >&2
fi
