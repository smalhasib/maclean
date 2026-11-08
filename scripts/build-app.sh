#!/bin/sh
# Builds Maclean in release and assembles .build/Maclean.app (no Xcode needed).
# Signs ad hoc unless MACLEAN_SIGN_IDENTITY names a signing identity.
# MACLEAN_UNIVERSAL=1 builds for both Apple silicon and Intel.
set -eu

cd "$(dirname "$0")/.."

arch_flags=""
if [ "${MACLEAN_UNIVERSAL:-0}" = 1 ]; then arch_flags="--arch arm64 --arch x86_64"; fi
# arch_flags is split on purpose.
swift build -c release $arch_flags --product Maclean
swift build -c release $arch_flags --product maclean-scan
bin_dir="$(swift build -c release $arch_flags --show-bin-path)"

app=".build/Maclean.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp "$bin_dir/Maclean" "$app/Contents/MacOS/Maclean"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
# The administrator helper the delete flow runs as root (AdminRunner).
cp "$bin_dir/maclean-scan" "$app/Contents/MacOS/maclean-scan"

# Nested code first, then the bundle.
codesign --force -s "${MACLEAN_SIGN_IDENTITY:--}" "$app/Contents/MacOS/maclean-scan"
codesign --force -s "${MACLEAN_SIGN_IDENTITY:--}" "$app"

echo "Built $app"
