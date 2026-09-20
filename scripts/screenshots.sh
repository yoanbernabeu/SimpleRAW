#!/bin/sh
# Takes the screenshots the README shows, so that they can be taken again.
#
# The photograph is given, never found. What is in `Samples/` is somebody else's work under a
# CC0 licence — fine to test a decoder against, wrong to put in a shop window — so this asks
# for a file and stops if it is not given one.
#
# A screenshot goes stale the moment the interface moves, and one nobody can reproduce goes
# stale quietly. Each state here is reached with launch arguments: AppKit files `-key value`
# pairs into the user defaults, which is how the inspector is told which panel to open without
# disturbing what you left on screen.
#
#   scripts/screenshots.sh ~/Pictures/one-of-mine.dng
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
out="Screenshots"

photo=${1:-}
if [ -z "$photo" ] || [ ! -f "$photo" ]; then
	echo "Give it one of your own photographs: scripts/screenshots.sh ~/Pictures/mine.dng [shoot-folder]" >&2
	exit 1
fi
# A grid of one photograph says nothing about a library. A second argument names a folder to
# import for that shot; without one, the library screenshot is skipped rather than filled with
# whatever happened to be lying about.
shoot=${2:-}

swift build -c release --product SimpleRAWApp
mkdir -p "$out"

stage=$(mktemp -d)
trap 'rm -rf "$stage"; pkill -f "release/SimpleRAWApp" 2>/dev/null || true' EXIT INT TERM
cp "$photo" "$stage/photo.${photo##*.}"
mkdir -p "$stage/library"

# The window id of our own app, which is usually behind the terminal: a full-screen capture
# would get the terminal instead. The **largest** of its windows, because a tooltip left on
# screen is a window too, and the first one found turned out to be one — a screenshot of the
# words "Curve, Color" and nothing else.
cat > "$stage/winid.swift" <<'SWIFT'
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let ours = list.filter { ($0[kCGWindowOwnerName as String] as? String)?.contains("SimpleRAW") == true }
func area(_ window: [String: Any]) -> Double {
    guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double else { return 0 }
    return width * height
}
if let biggest = ours.max(by: { area($0) < area($1) }), let number = biggest[kCGWindowNumber as String] as? Int {
    print(number)
}
SWIFT
swiftc -O "$stage/winid.swift" -o "$stage/winid"

shoot() {
	name=$1
	shift
	pkill -f "release/SimpleRAWApp" 2>/dev/null || true
	sleep 1
	if [ "$name" = "library" ]; then
		.build/release/SimpleRAWApp -library "$stage/library" "$@" &
	else
		.build/release/SimpleRAWApp -library "$stage/library" -file "$stage"/photo.* "$@" &
	fi
	sleep "${shoot_seconds:-11}"
	# Nothing under the pointer: a tooltip in a screenshot is a tooltip for ever.
	osascript -e 'tell application "System Events" to set position of mouse cursor to {5, 5}' 2>/dev/null || true
	id=$("$stage/winid")
	[ -n "$id" ] || { echo "no window for $name" >&2; return 1; }
	screencapture -x -o -l "$id" "$stage/$name.png"
	# 1400 points wide: sharp in a README, and a few hundred kilobytes rather than seven
	# megabytes of Retina.
	sips -Z 1400 -s format jpeg -s formatOptions 88 "$stage/$name.png" --out "$out/$name.jpg" >/dev/null
	echo "$out/$name.jpg"
}

# The built-in "Black & white", written out: a looks panel showing a neutral photograph says
# nothing about what a look does. `simpleraw presets` lists them; this is that one's content.
cat > "$stage/black-and-white.json" <<'JSON'
{
  "blackAndWhite": { "isEnabled": true, "red": 20, "blue": -25 },
  "curves": { "rgb": { "points": [
    { "x": 0, "y": 0 }, { "x": 0.25, "y": 0.2 }, { "x": 0.75, "y": 0.82 }, { "x": 1, "y": 1 }
  ] } }
}
JSON

if [ -n "$shoot" ] && [ -d "$shoot" ]; then
	.build/release/simpleraw import "$shoot" --library "$stage/library" >/dev/null
	# No `-file`, so the app opens on the grid. Longer, because every cell is decoded.
	shoot_seconds=26 shoot library
fi

shoot develop -inspector.tab light -inspector.openPanels "light=Light"
shoot crop -crop YES
shoot looks -look "$stage/black-and-white.json" -inspector.tab creative -inspector.openPanels "creative=Looks"

pkill -f "release/SimpleRAWApp" 2>/dev/null || true
