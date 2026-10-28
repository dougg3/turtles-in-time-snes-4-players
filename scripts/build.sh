#!/usr/bin/env bash
# clean ROM -> source patches -> asar -> patched ROM (+ BPS)
#   scripts/build.sh [us|eu|au|jp]   (default us; the others: scripts/variants.py)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
variant="${1:-us}"
defs=""
case "$variant" in
  us) clean="$root/original/Teenage Mutant Ninja Turtles IV - Turtles in Time (USA).sfc"; expected_sha1=4f8fc0f45023e0339e501054b253c33f479a001a; suffix="" ;;
  eu) clean="$root/original/Teenage Mutant Hero Turtles IV - Turtles in Time (Europe).sfc"; expected_sha1=59add584f16b607607348e65c245ca6ad7a5fcb8; suffix="-eu" ;;
  au) clean="$root/original/Teenage Mutant Ninja Turtles IV - Turtles in Time (Australia).sfc"; expected_sha1=c4ba9b0fd1b40a228e6bb1170ec227dac5b83ce5; suffix="-au" ;;
  jp) clean="$root/original/Teenage Mutant Ninja Turtles - Turtles in Time (Japan).sfc"; expected_sha1=514e7fb70e1e5e06c5a873262e145a555655d62d; suffix="-jp"; defs="-DJP=1" ;;
  *) echo "usage: $0 [us|eu|au|jp]" >&2; exit 1 ;;
esac
out="$root/build/tmnt4-4p$suffix.sfc"

echo "$expected_sha1  $clean" | sha1sum -c --quiet
# Asar assembles a relative branch to a NUMBER (e.g. `bra $ADD0`) as a raw operand
# byte, not as a target address. Targets must be labels.
if grep -nE '^\s*(bra|bcc|bcs|beq|bne|bmi|bpl|bvc|bvs|brl)\s+\$' "$root"/patches/*.asm; then
  echo "error: branch with a numeric target (use a label)" >&2; exit 1
fi
mkdir -p "$root/build"
python3 "$root/scripts/gen_select_glyphs.py" "$root/patches/select4_glyphs.asm"
src="$root/patches"
if [ "$variant" != us ]; then
  # the USA builds first: the check compares the variant's changes with theirs
  [ -n "${SKIP_USA:-}" ] || SKIP_USA=1 "$0" us >/dev/null
  src="$root/build/variants/$variant/patches"
  python3 "$root/scripts/variants.py" translate "$variant" "$src"
fi
cp "$clean" "$out"
chmod u+w "$out"
"$root/tools/bin/asar" --fix-checksum=on $defs --symbols=wla --symbols-path="${out%.sfc}.sym" "$src/main.asm" "$out"
"$root/tools/bin/flips" --create --bps "$clean" "$out" "${out%.sfc}-patch.bps" >/dev/null || true
sha1sum "$out"
if [ "$variant" != us ]; then
  # changes must be the images of the USA build's changes, or variant free space
  python3 "$root/scripts/variants.py" check "$variant" "$out" "$root/build/tmnt4-4p.sfc"
  exit 0
fi
# Patched bytes must not contain an original branch/loop target (needs recorded CDL files).
cdls=$(ls "$root"/build/cdl/*.cdl 2>/dev/null || true)
if [ -n "$cdls" ]; then
  python3 "$root/scripts/check_hooks.py" "$clean" "$out" $cdls --ignore 00:C15F > "$root/build/check_hooks.txt" \
    || { cat "$root/build/check_hooks.txt" >&2; echo "error: patch overwrites a branch target" >&2; exit 1; }
fi
