#!/bin/sh
# Builds a universal Maclean.app and zips it for a GitHub release.
# Prints the zip path and its SHA-256 (for the Homebrew cask).
set -eu

cd "$(dirname "$0")/.."

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
MACLEAN_UNIVERSAL=1 scripts/build-app.sh

zip=".build/Maclean-$version.zip"
rm -f "$zip"
ditto -c -k --keepParent .build/Maclean.app "$zip"

echo "Version: $version"
echo "Zip:     $zip"
echo "SHA-256: $(shasum -a 256 "$zip" | cut -d' ' -f1)"
