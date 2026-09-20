#!/bin/sh
# Compiles Core Image kernels into one Metal library.
#
# The `metal` compiler comes with Xcode's Metal toolchain, not with the Command Line Tools.
# Where it is missing this writes an empty file and says so: the build goes through, and the
# stages that need a kernel find no library and leave the picture alone.
set -eu
output="$1"
shift

if ! xcrun --find metal >/dev/null 2>&1; then
    echo "note: no Metal compiler (Xcode's Metal toolchain); kernels are left out of this build"
    : > "$output"
    exit 0
fi

work="$(dirname "$output")"
airs=""
for source in "$@"; do
    air="$work/$(basename "$source" .ci.metal).air"
    xcrun metal -c -fcikernel "$source" -o "$air"
    airs="$airs $air"
done
# shellcheck disable=SC2086
xcrun metallib -cikernel $airs -o "$output"
