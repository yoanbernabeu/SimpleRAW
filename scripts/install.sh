#!/bin/sh
# Installs SimpleRAW from its latest release.
#
# Short on purpose: you may be about to run this straight off the internet, and a script you
# cannot read in one sitting is a script nobody reads. What it does, in order:
#
#   1. asks GitHub for the latest release and downloads SimpleRAW.zip,
#   2. unzips it into /Applications (or ~/Applications, if the first is not writable),
#   3. takes the quarantine flag off the bundle it just installed.
#
# That third step is the one to think about. The app is signed ad-hoc — there is no Apple
# Developer certificate behind this project — so macOS marks anything downloaded and Gatekeeper
# refuses to open it. Removing the flag is the same thing as right-clicking the app and
# choosing Open, and you should do it only for software you have reason to trust. Nothing here
# asks for a password, and nothing is written outside the application folder.
#
#   curl -fsSL https://raw.githubusercontent.com/yoanbernabeu/SimpleRAW/main/scripts/install.sh | sh
set -eu

repository=${SIMPLERAW_REPOSITORY:-yoanbernabeu/SimpleRAW}
app="SimpleRAW.app"

# /Applications, unless the environment names somewhere else — which is how a fork, and the test
# that runs this script for real, installs without being handed the whole machine.
destination=${SIMPLERAW_DESTINATION:-}
if [ -n "$destination" ]; then
	mkdir -p "$destination"
elif [ -w "/Applications" ]; then
	destination="/Applications"
else
	destination="$HOME/Applications"
	mkdir -p "$destination"
	echo "No write access to /Applications; installing into $destination."
fi

# Braces, because of the ellipsis: bash 3.2 in a UTF-8 locale takes the first byte of a `…` for
# a letter and reads the name as `repository…`, which under `set -u` ends the installer here.
echo "Looking for the latest release of ${repository}…"
# A release asset, not any link that happens to end in SimpleRAW.zip: the release notes are the
# README, and the README talks about the archive too.
url=$(curl -fsSL "https://api.github.com/repos/$repository/releases/latest" \
	| grep -o 'https://[^"]*/releases/download/[^"]*SimpleRAW\.zip' | head -1)
if [ -z "$url" ]; then
	echo "No SimpleRAW.zip in the latest release of $repository." >&2
	exit 1
fi

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT INT TERM

echo "Downloading $url"
curl -fsSL "$url" -o "$stage/SimpleRAW.zip"
# ditto, not unzip: the signature lives in extended attributes, and unzip drops them.
ditto -x -k "$stage/SimpleRAW.zip" "$stage"

if [ ! -d "$stage/$app" ]; then
	echo "That archive holds no $app." >&2
	exit 1
fi

rm -rf "${destination:?}/$app"
ditto "$stage/$app" "$destination/$app"

# The one step that needs saying out loud.
echo "Removing the quarantine flag from $destination/$app"
xattr -dr com.apple.quarantine "$destination/$app" 2>/dev/null || true

echo "Installed $destination/$app — open it from the Finder, or: open \"$destination/$app\""
