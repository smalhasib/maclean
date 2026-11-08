#!/bin/sh
# Builds a universal, signed Maclean.app, zips it and signs the zip for a GitHub release.
#
#   MACLEAN_SIGN_IDENTITY  code-signing identity (default: "Maclean Release" from your Keychain;
#                          create it once with scripts/make-signing-cert.sh)
#   MACLEAN_UPDATE_KEY     Ed25519 update key file (default: ~/.config/maclean/update-key;
#                          create it with `swift scripts/update-key.swift generate <file>`)
#
# Prints the zip path, the .sig path and the zip's SHA-256 (for the Homebrew cask).
set -eu

cd "$(dirname "$0")/.."

if [ -z "${MACLEAN_SIGN_IDENTITY:-}" ]; then
    if security find-identity -v -p codesigning | grep -q '"Maclean Release"'; then
        MACLEAN_SIGN_IDENTITY="Maclean Release"
    else
        echo "No signing identity. Run scripts/make-signing-cert.sh once, or set MACLEAN_SIGN_IDENTITY." >&2
        exit 1
    fi
fi
export MACLEAN_SIGN_IDENTITY

key="${MACLEAN_UPDATE_KEY:-$HOME/.config/maclean/update-key}"
if [ ! -f "$key" ]; then
    echo "No update key at $key." >&2
    echo "Create one with: mkdir -p ~/.config/maclean && swift scripts/update-key.swift generate ~/.config/maclean/update-key" >&2
    echo "then put the printed public key in Sources/MacleanCore/UpdateKey.swift. Or set MACLEAN_UPDATE_KEY." >&2
    exit 1
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
MACLEAN_UNIVERSAL=1 scripts/build-app.sh

zip=".build/Maclean-$version.zip"
rm -f "$zip" "$zip.sig"
ditto -c -k --keepParent .build/Maclean.app "$zip"
swift scripts/update-key.swift sign "$key" "$zip"

echo "Version:   $version"
echo "Identity:  $MACLEAN_SIGN_IDENTITY"
echo "Zip:       $zip"
echo "Signature: $zip.sig"
echo "SHA-256:   $(shasum -a 256 "$zip" | cut -d' ' -f1)"
