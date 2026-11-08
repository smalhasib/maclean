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
    # Count "Maclean Release" identities, trusted or not (`-v` lists only valid
    # ones), stopping at "Valid identities only", which repeats the valid ones.
    count="$(security find-identity -p codesigning |
        awk '/Valid identities only/ { exit } index($0, "\"Maclean Release\"") { c++ } END { print c + 0 }')"
    if [ "$count" -eq 1 ]; then
        MACLEAN_SIGN_IDENTITY="Maclean Release"
    elif [ "$count" -gt 1 ]; then
        echo "\"Maclean Release\" is in your Keychain $count times; codesign can't tell them apart." >&2
        echo "Delete the extra copies in Keychain Access, or set MACLEAN_SIGN_IDENTITY to one certificate's hash." >&2
        exit 1
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

# The key must match the public key built into the app, or every installed copy
# refuses the update. Checked before the (slow) build and before signing.
placeholder="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
embedded="$(sed -n 's/.*publicKeyBase64 = "\([^"]*\)".*/\1/p' Sources/MacleanCore/UpdateKey.swift)"
if [ -z "$embedded" ] || [ "$embedded" = "$placeholder" ]; then
    echo "Sources/MacleanCore/UpdateKey.swift still has the all-zero placeholder key; no copy would accept this release." >&2
    echo "Put your public key there first (swift scripts/update-key.swift public \"$key\")." >&2
    exit 1
fi
public="$(swift scripts/update-key.swift public "$key")"
if [ "$public" != "$embedded" ]; then
    echo "The update key $key doesn't match the public key in Sources/MacleanCore/UpdateKey.swift;" >&2
    echo "every installed copy would refuse this release." >&2
    echo "  key file: $public" >&2
    echo "  embedded: $embedded" >&2
    exit 1
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
MACLEAN_UNIVERSAL=1 scripts/build-app.sh

zip=".build/Maclean-$version.zip"
rm -f "$zip" "$zip.sig"
ditto -c -k --keepParent .build/Maclean.app "$zip"
swift scripts/update-key.swift sign "$key" "$zip"

# A disk image for people who download by hand: the app next to an Applications
# shortcut. The updater and the cask use the zip, so the dmg isn't signed with the update key.
dmg=".build/Maclean-$version.dmg"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
ditto .build/Maclean.app "$stage/Maclean.app"
ln -s /Applications "$stage/Applications"
rm -f "$dmg"
hdiutil create -quiet -volname Maclean -srcfolder "$stage" -format UDZO -ov "$dmg"

echo "Version:   $version"
echo "Identity:  $MACLEAN_SIGN_IDENTITY"
echo "Zip:       $zip"
echo "Signature: $zip.sig"
echo "Disk image: $dmg"
echo "SHA-256:   $(shasum -a 256 "$zip" | cut -d' ' -f1)"
