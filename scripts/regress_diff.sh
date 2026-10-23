#!/usr/bin/env bash
# Dump WRAM at several frames of one regression scenario on both ROMs and list the
# low-WRAM bytes that differ (honoring tests/hash_exclude.txt and hash_map.txt).
#   regress_diff.sh SCENARIO WAIT1 [WAIT2 ...]    (waits relative to the scenario start)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
sc="$root/tests/scenarios/$1.txt"; shift
out="$root/build/runs/rdiff/$(basename "$sc" .txt)"; mkdir -p "$out"
{ grep -vE '^(bg |wait|end)' "$sc"; i=0; for w in "$@"; do echo "wait $w"; echo "wram w$i"; i=$((i+1)); done; echo end; } > "$out/cmds.txt"
export MESEN_ARGS="--Snes.PpuExtraScanlinesBeforeNmi=400"
"$root/scripts/mesen-run.sh" "$out/cmds.txt" "$out/o" "$root/original/Teenage Mutant Ninja Turtles IV - Turtles in Time (USA).sfc" > /dev/null
"$root/scripts/mesen-run.sh" "$out/cmds.txt" "$out/n" "$root/build/tmnt4-4p.sfc" > /dev/null
python3 - "$out" "$root" $# <<'P'
import sys
out,root,n=sys.argv[1],sys.argv[2],int(sys.argv[3])
ex=set()
for part in open(root+'/tests/hash_exclude.txt').read().strip().split(','):
    a,_,b=part.partition('-'); a=int(a,16); b=int(b,16) if b else a; ex.update(range(a,b+1))
mp=[tuple(int(x,16) for x in m.split(':')) for m in open(root+'/tests/hash_map.txt').read().strip().split(',')]
for i in range(n):
    o=open(f'{out}/o/w{i}.wram','rb').read(); w=bytearray(open(f'{out}/n/w{i}.wram','rb').read())
    for src,dst,l in mp: w[src:src+l]=w[dst:dst+l]
    d=[a for a in range(0x2000) if o[a]!=w[a] and a not in ex]
    print(f"w{i}: {len(d)} bytes differ:", " ".join(f"{a:04X}:{o[a]:02X}/{w[a]:02X}" for a in d[:24]))
P
