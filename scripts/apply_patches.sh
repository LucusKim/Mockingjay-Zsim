#!/bin/bash
# Apply the Mockingjay changes to a zsim source tree.
#
# Usage:
#   scripts/apply_patches.sh casim <path/to/casim-csce614/zsim>
#       Tree already has the course baseline: applies patches 0002-0004.
#   scripts/apply_patches.sh upstream <path/to/zsim>
#       Clean s5z/zsim checkout (tested on f524c05): applies all four patches.
#
# Also copies the Mockingjay configs and run script into the tree.

set -e
REPO="$(cd "$(dirname "$0")/.." && pwd)"

if [ "$#" -ne 2 ] || { [ "$1" != "casim" ] && [ "$1" != "upstream" ]; }; then
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
fi

MODE=$1
ZSIM="$(cd "$2" && pwd)"
[ -f "$ZSIM/src/cache.cpp" ] || { echo "$ZSIM does not look like a zsim tree" >&2; exit 1; }

if [ "$MODE" = "upstream" ]; then
    PATCHES=("$REPO"/patches/000[1-4]-*.patch)
else
    PATCHES=("$REPO"/patches/000[2-4]-*.patch)
fi

cd "$ZSIM"
for p in "${PATCHES[@]}"; do
    echo "Applying $(basename "$p")"
    patch -p1 --forward < "$p"
done

mkdir -p configs/hw4
cp -r "$REPO"/zsim/configs/hw4/* configs/hw4/
cp "$REPO"/zsim/run_mockingjay.sh "$REPO"/zsim/hw4runscript .
chmod +x run_mockingjay.sh hw4runscript

echo
echo "Done. Rebuild with: cd $ZSIM && scons -j4"
