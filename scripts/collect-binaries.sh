#!/bin/sh
# Copy the programs from a build directory into a distribution
# directory, with the licence and the fork's notes. Test programs are
# left out. Used by CI to publish binaries.
#
# Usage: scripts/collect-binaries.sh <build dir> <dist dir>

set -eu

build=$1
dist=$2
src=$(cd "$(dirname "$0")/.." && pwd)

mkdir -p "$dist"
found=0
for prog in putty pterm puttytel plink pscp psftp psusan psocks \
            puttygen pageant; do
    for f in "$build/$prog" "$build/$prog.exe"; do
        if [ -f "$f" ]; then
            cp "$f" "$dist/"
            found=$((found + 1))
        fi
    done
done

if [ "$found" -eq 0 ]; then
    echo "no programs found in $build" >&2
    exit 1
fi

# The MIT licence has to travel with the binaries (the command-line
# tools don't display it).
cp "$src/LICENCE" "$src/FORK.md" "$dist/"
ls -l "$dist"
