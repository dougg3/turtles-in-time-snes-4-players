#!/usr/bin/env bash
# clean ROM -> source patches -> asar -> patched ROM (+ BPS)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
clean="$root/original/Teenage Mutant Ninja Turtles IV - Turtles in Time (USA).sfc"
out="$root/build/tmnt4-4p.sfc"
expected_sha1=4f8fc0f45023e0339e501054b253c33f479a001a

echo "$expected_sha1  $clean" | sha1sum -c --quiet
# Asar assembles a relative branch to a NUMBER (e.g. `bra $ADD0`) as a raw operand
# byte, not as a target address. Targets must be labels.
if grep -nE '^\s*(bra|bcc|bcs|beq|bne|bmi|bpl|bvc|bvs|brl)\s+\$' "$root"/patches/*.asm; then
  echo "error: branch with a numeric target (use a label)" >&2; exit 1
fi
mkdir -p "$root/build"
python3 "$root/scripts/gen_select_glyphs.py" "$root/patches/select4_glyphs.asm"
cp "$clean" "$out"
chmod u+w "$out"
"$root/tools/bin/asar" --fix-checksum=on --symbols=wla --symbols-path="$root/build/tmnt4-4p.sym" "$root/patches/main.asm" "$out"
"$root/tools/bin/flips" --create --bps "$clean" "$out" "$root/build/tmnt4-4p.bps" >/dev/null || true
sha1sum "$out"
# Patched bytes must not contain an original branch/loop target (needs recorded CDL files).
cdls=$(ls "$root"/build/runs/*/*.cdl 2>/dev/null || true)
if [ -n "$cdls" ]; then
  python3 "$root/scripts/check_hooks.py" "$clean" "$out" $cdls --ignore 00:C15F > "$root/build/check_hooks.txt" \
    || { cat "$root/build/check_hooks.txt" >&2; echo "error: patch overwrites a branch target" >&2; exit 1; }
fi
