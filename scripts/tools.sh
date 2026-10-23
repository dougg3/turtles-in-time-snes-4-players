# The tools scripts/setup.sh builds into tools/, and the compiler (sourced by setup.sh)
ASAR_REPO=https://github.com/RPGHacker/asar.git
ASAR_TAG=v1.91
FLIPS_REPO=https://github.com/Alcaro/Flips.git
FLIPS_COMMIT=ff216a75df0987047a67d7923567dc4482ce07ac
MESEN_REPO=https://github.com/nesdev-org/MesenCE.git
MESEN_COMMIT=4b8a196e
DOTNET_CHANNEL=10.0                 # what Mesen's UI targets (net10.0)

# clang, or the newest versioned one (Ubuntu installs clang++-18 etc.)
CLANGXX=$(command -v clang++ || ls /usr/bin/clang++-[0-9]* 2> /dev/null | sort -t- -k2 -n | tail -1 || true)
CLANG=${CLANGXX/clang++/clang}
