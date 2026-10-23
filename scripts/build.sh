#!/usr/bin/env bash
# clean ROM -> source patches -> asar -> patched ROM (+ BPS)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
clean="$root/original/Teenage Mutant Ninja Turtles IV - Turtles in Time (USA).sfc"
out="$root/build/tmnt4-4p.sfc"
expected_sha1=4f8fc0f45023e0339e501054b253c33f479a001a

echo "$expected_sha1  $clean" | sha1sum -c --quiet
mkdir -p "$root/build"
cp "$clean" "$out"
chmod u+w "$out"
"$root/tools/bin/asar" --fix-checksum=on "$root/patches/main.asm" "$out"
"$root/tools/bin/flips" --create --bps "$clean" "$out" "$root/build/tmnt4-4p.bps" >/dev/null || true
sha1sum "$out"
