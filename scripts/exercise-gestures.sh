#!/bin/sh
# Drives the real app with real mouse events and reports which gestures answer.
#
# Every other test in this project calls the method a gesture calls. This one presses the
# mouse: it is the only thing that says whether the press reaches the slider, whether a
# handle sits where the picture is, whether a tool takes the drag at all.
#
# The photograph is copied out of Samples/ first — the app writes a sidecar next to whatever
# it opens, and Samples/ must come out of a run exactly as it went in. The library is a
# throwaway too, so that nothing touches the one the photographer uses.
#
# The app has to be allowed to come to the front: a window nobody is talking to swallows the
# press that would make it the one being talked to, and every gesture then reads as dead. The
# run says "inconclusive" when it cannot get there, rather than blaming the tools.
#
#   scripts/exercise-gestures.sh [gesture name]    (default: all of them)
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
gestures=${1:-all}
if [ -z "$gestures" ]; then gestures=all; fi

photo=$(ls "$root"/Samples/R0000357.DNG 2>/dev/null || ls "$root"/Samples/*.[dD][nN][gG] 2>/dev/null | head -1)
if [ -z "${photo:-}" ]; then
	echo "No DNG in Samples/: a scripted gesture needs a photograph (see CLAUDE.md)." >&2
	exit 1
fi

# Release, like `make run`: in debug a lookup table takes a hundred milliseconds to build and
# a drag crawls for a reason no user will ever meet.
swift build -c release --product SimpleRAWApp

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT INT TERM
cp "$photo" "$stage/photo.dng"
mkdir -p "$stage/library"

.build/memory-guard 12 .build/release/SimpleRAWApp \
	-library "$stage/library" -file "$stage/photo.dng" -gestures "$gestures"
