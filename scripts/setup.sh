#!/usr/bin/env bash
# Download and build the tools into tools/, at the versions in scripts/tools.sh:
#   scripts/setup.sh        Asar (tools/bin/asar), Flips (tools/bin/flips) and Mesen
#                           (tools/mesen/Mesen, with the .NET SDK it needs in tools/dotnet)
# Nothing is installed outside tools/. Run it again after a version changes; finished
# steps are skipped. Needs git, curl, make, cmake, clang, Python 3 and the SDL2 development
# files (see README.md).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/scripts/tools.sh"
tools="$root/tools"
mkdir -p "$tools/src" "$tools/bin"
jobs="$(nproc)"

for cmd in git curl make cmake python3; do
  command -v $cmd > /dev/null || { echo "setup: $cmd is missing"; exit 1; }
done
[ -n "$CLANGXX" ] || { echo "setup: clang is missing"; exit 1; }
cxx="$CLANGXX" cc="$CLANG"
pkg-config --exists sdl2 2> /dev/null || { echo "setup: the SDL2 development files are missing (libsdl2-dev)"; exit 1; }

# fetch REPO REF DIR: DIR at REF (a tag or commit)
fetch() {
  [ -d "$3/.git" ] || git clone -q "$1" "$3"
  git -C "$3" fetch -q --tags origin 2> /dev/null || true
  git -C "$3" -c advice.detachedHead=false checkout -q "$2"
}
# stamp NAME VALUE: true if the step NAME was finished for VALUE
stamp() { [ "$(cat "$tools/.$1" 2> /dev/null)" = "$2" ]; }

if ! stamp asar "$ASAR_TAG"; then
  echo "Asar $ASAR_TAG"
  fetch "$ASAR_REPO" "$ASAR_TAG" "$tools/src/asar"
  { cmake -S "$tools/src/asar/src" -B "$tools/src/asar/build" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_CXX_COMPILER="$cxx" -DCMAKE_C_COMPILER="$cc" &&
    cmake --build "$tools/src/asar/build" --target asar-standalone -j"$jobs"; } > "$tools/src/asar.log" 2>&1 \
    || { tail -20 "$tools/src/asar.log"; echo "setup: Asar failed (tools/src/asar.log)"; exit 1; }
  cp "$tools/src/asar/build/asar/bin/asar" "$tools/bin/asar"
  echo "$ASAR_TAG" > "$tools/.asar"
fi

if ! stamp flips "$FLIPS_COMMIT"; then
  echo "Flips ${FLIPS_COMMIT:0:8}"
  fetch "$FLIPS_REPO" "$FLIPS_COMMIT" "$tools/src/flips"
  make -C "$tools/src/flips" TARGET=cli CXX="$cxx" CC="$cc" -j"$jobs" > "$tools/src/flips.log" 2>&1 \
    || { tail -20 "$tools/src/flips.log"; echo "setup: Flips failed (tools/src/flips.log)"; exit 1; }
  cp "$tools/src/flips/flips" "$tools/bin/flips"
  echo "$FLIPS_COMMIT" > "$tools/.flips"
fi

# .NET SDK and its packages, in tools/ only
export DOTNET_ROOT="$tools/dotnet" NUGET_PACKAGES="$tools/nuget"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
export PATH="$DOTNET_ROOT:$PATH"
if ! stamp dotnet "$DOTNET_CHANNEL"; then
  echo ".NET SDK $DOTNET_CHANNEL"
  curl -sSfL https://dot.net/v1/dotnet-install.sh -o "$tools/src/dotnet-install.sh"
  bash "$tools/src/dotnet-install.sh" --channel "$DOTNET_CHANNEL" --install-dir "$DOTNET_ROOT" --no-path > /dev/null
  echo "$DOTNET_CHANNEL" > "$tools/.dotnet"
fi

if ! stamp mesen "$MESEN_COMMIT"; then
  echo "Mesen $MESEN_COMMIT (a few minutes)"
  src="$tools/src/mesen"
  fetch "$MESEN_REPO" "$MESEN_COMMIT" "$src"
  # the makefile doesn't track header dependencies: build from scratch. USE_AOT: a native
  # program that runs without .NET (only the build needs it)
  make -C "$src" clean > /dev/null 2>&1 || true
  make -C "$src" -j"$jobs" CXX="$cxx" CC="$cc" USE_AOT=true > "$tools/src/mesen.log" 2>&1 \
    || { tail -20 "$tools/src/mesen.log"; echo "setup: Mesen failed (tools/src/mesen.log)"; exit 1; }
  # portable: with settings.json next to it, Mesen keeps its settings and the files it
  # unpacks (its core among them) in tools/mesen, apart from any other Mesen
  mkdir -p "$tools/mesen"
  rm -f "$tools/mesen/MesenCore.so"     # unpacked again from the new build
  for f in Mesen libSkiaSharp.so libHarfBuzzSharp.so; do    # the program and its UI libraries
    cp "$src/bin/linux-x64/Release/linux-x64/publish/$f" "$tools/mesen/$f"
  done
  # the test runner and the bots are Lua scripts that read and write files, and take
  # more than the default 1 s per call
  [ -f "$tools/mesen/settings.json" ] ||
    echo '{"Debug": {"ScriptWindow": {"AllowIoOsAccess": true, "ScriptTimeout": 10}}}' > "$tools/mesen/settings.json"
  echo "$MESEN_COMMIT" > "$tools/.mesen"
fi

echo "tools ready"
