#!/usr/bin/env bash
# Create the regression start states from the CLEAN ROM: power-on -> 2P -> scene N
# -> save state right after the stage begins. States hold game RAM, so they live
# in build/ (not in git). Usage: scripts/make_regress_states.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$root/build/regress/states"; mkdir -p "$dest"
for st in 0 1 2 3 4 5 6 7 8 9; do
  cat > "$dest/make$st.txt" <<CMDS
wait 900
tap 0 start
wait 300
tap 0 down
wait 20
tap 0 start
wait 400
poke 82 $(printf %02X $st) 00
tap 0 b 4
wait 10
tap 1 b 4
wait 200
tap 0 start 4
wait 60
tap 0 start 4
wait 400
save start.mss
end
CMDS
done
ls "$dest"/make*.txt | xargs -P3 -I{} sh -c 'n=$(basename {} .txt); MESEN_TIMEOUT=300 "'"$root"'/scripts/mesen-run.sh" {} "'"$dest"'/$n" "'"$root"'/original/Teenage Mutant Ninja Turtles IV - Turtles in Time (USA).sfc" > /dev/null 2>&1'
for st in 0 1 2 3 4 5 6 7 8 9; do cp "$dest/make$st/start.mss" "$dest/scene$((st + 1)).mss"; done
ls -la "$dest"/*.mss
