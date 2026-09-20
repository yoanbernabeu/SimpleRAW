#!/bin/sh
# Compiles Core Image kernels into one Metal library.
#
# The `metal` compiler comes with Xcode's Metal toolchain, not with the Command Line Tools.
# Where it is missing this writes an empty file and says so: the build goes through, and the
# stages that need a kernel find no library and leave the picture alone.
#
# **And where it is there but cannot run**, the same. A build-tool plugin runs in a sandbox
# that may write only to its own output folder, and on a fresh machine the compiler's first
# act is to build the Metal standard library into a module cache somewhere under /var — which
# it is not allowed to do. That is how a green build on one machine failed on a runner. The
# compiler is given a cache inside the folder it *is* allowed to write to; and if it still
# fails, the build goes through without kernels rather than stopping, with the reason printed
# where it cannot be missed.
set -eu
output="$1"
shift

work="$(dirname "$output")"

# Empty is the same as missing, to everything downstream: `MetalKernels.isAvailable` is false,
# the stage passes the picture on and the slider is not offered.
without_kernels() {
    : > "$output"
    exit 0
}

if ! xcrun --find metal >/dev/null 2>&1; then
    echo "note: no Metal compiler (Xcode's Metal toolchain); kernels are left out of this build"
    without_kernels
fi

cache="$work/module-cache"
mkdir -p "$cache"

airs=""
for source in "$@"; do
    air="$work/$(basename "$source" .ci.metal).air"
    if ! xcrun metal -c -fcikernel -fmodules-cache-path="$cache" "$source" -o "$air"; then
        echo "warning: $(basename "$source") did not compile; this build has no Core Image kernels"
        echo "warning: the distortion slider will not be offered. The compiler's reason is above."
        without_kernels
    fi
    airs="$airs $air"
done

# shellcheck disable=SC2086
if ! xcrun metallib -cikernel $airs -o "$output"; then
    echo "warning: the kernels compiled but would not link into a library; this build has none"
    without_kernels
fi
