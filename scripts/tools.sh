# The tools scripts/setup.sh builds into tools/, and the compiler (sourced by setup.sh and
# build_web.sh)
ASAR_REPO=https://github.com/RPGHacker/asar.git
ASAR_TAG=v1.91
FLIPS_REPO=https://github.com/Alcaro/Flips.git
FLIPS_COMMIT=ff216a75df0987047a67d7923567dc4482ce07ac
MESEN_TMNT4P_REPO=${MESEN_TMNT4P_REPO:-https://github.com/dougg3/mesen-tmnt4p.git}
MESEN_TMNT4P_COMMIT=d83c0fcf
DOTNET_CHANNEL=10.0                 # what Mesen's UI targets (net10.0)
EMSDK_REPO=https://github.com/emscripten-core/emsdk.git
EMSDK_VERSION=6.0.13

# clang, or the newest versioned one (Ubuntu installs clang++-18 etc.)
CLANGXX=$(command -v clang++ || ls /usr/bin/clang++-[0-9]* 2> /dev/null | sort -t- -k2 -n | tail -1 || true)
CLANG=${CLANGXX/clang++/clang}
