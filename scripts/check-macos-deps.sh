#!/bin/sh
# Check that the macOS programs in a build directory depend only on
# libraries and frameworks that ship with macOS (nothing from Homebrew,
# MacPorts, /usr/local and so on), so they run on a stock Mac.
#
# Usage: scripts/check-macos-deps.sh <build dir>

set -eu

build=$1
bad=0
checked=0

for f in "$build/PuTTY.app/Contents/MacOS/PuTTY" \
         "$build"/plink "$build"/pscp "$build"/psftp "$build"/psocks \
         "$build"/psusan "$build"/puttygen "$build"/pageant; do
    [ -f "$f" ] || continue
    checked=$((checked + 1))
    # The first line of otool -L output names the file itself.
    deps=$(otool -L "$f" | tail -n +2 | awk '{print $1}')
    for d in $deps; do
        case "$d" in
          /usr/lib/*|/System/Library/*) ;;
          *)
            echo "$f: depends on $d, which isn't part of macOS" >&2
            bad=1
            ;;
        esac
    done
    echo "$f: OK"
done

if [ "$checked" -eq 0 ]; then
    echo "no programs found in $build" >&2
    exit 1
fi
exit $bad
