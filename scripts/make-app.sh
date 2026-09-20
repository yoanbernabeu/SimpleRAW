#!/bin/sh
# Wraps the SwiftPM executable in a real app bundle, sandboxed and signed.
#
# Until now the app ran bare out of `.build`: no Finder integration, no double-click, and —
# the reason this exists — no sandbox, so decoding a booby-trapped RAW reached the whole home
# folder. The wrapper closes that.
#
# The property list and the rights come from `simpleraw plist`, never from a copy kept here:
# the file types the Finder offers the app for are the ones the importer actually reads.
#
# The signature is ad-hoc (`-`), which is all this machine needs to run a sandboxed app.
# Developer ID and notarisation — what another machine needs — wait for the account.
#
#   scripts/make-app.sh              build it
#   scripts/make-app.sh --open       build it and start it
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
app=".build/SimpleRAW.app"

# One at a time: `swift build` keeps only the last `--product` it is given, so asking for two
# in one command silently builds one of them. Here that left the app unbuilt and the copy
# below failing, and it went unnoticed because a previous build had left the binary behind.
swift build -c release --product SimpleRAWApp
swift build -c release --product simpleraw

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp .build/release/SimpleRAWApp "$app/Contents/MacOS/SimpleRAW"

# The resource bundle carries the compiled Core Image kernels. Bare, it is found because it
# sits next to the executable; in a wrapper it has to go where `Bundle.module` looks, which is
# Contents/Resources. Forget it and the distortion slider disappears without a word.
if [ -d .build/release/SimpleRAW_RawEngine.bundle ]; then
	cp -R .build/release/SimpleRAW_RawEngine.bundle "$app/Contents/Resources/"
fi

# Looks, moods and the edits of files outside the library live in Application Support, which
# inside a sandbox means the app's container. Anything an unwrapped build wrote is in the
# usual place, which the wrapped app may no longer read: this is the one moment that can see
# both, so it brings them over — once, and never over anything already there.
container="$HOME/Library/Containers/$(.build/release/simpleraw plist | plutil -extract CFBundleIdentifier raw -)/Data/Library/Application Support/SimpleRAW"
previous="$HOME/Library/Application Support/SimpleRAW"
if [ -d "$previous" ] && [ ! -d "$container" ]; then
	mkdir -p "$(dirname "$container")"
	cp -R "$previous" "$container"
	echo "Brought over $previous"
fi

.build/release/simpleraw plist > "$app/Contents/Info.plist"
.build/release/simpleraw plist --entitlements > .build/SimpleRAW.entitlements
printf 'APPL????' > "$app/Contents/PkgInfo"

# The hardened runtime with no way out of it, and the sandbox from the entitlements. Deep,
# because the resource bundle is signed too.
codesign --force --deep --options runtime \
	--entitlements .build/SimpleRAW.entitlements \
	--sign - "$app"
codesign --verify --deep --strict "$app"

echo "Built $app"
codesign --display --entitlements - "$app" 2>/dev/null | grep -A 20 "<?xml" || true

if [ "${1:-}" = "--open" ]; then
	open "$app"
fi
