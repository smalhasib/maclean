#!/bin/sh
# Decides the next release from the commits since the last v* tag.
#
#   next-release.sh [major|minor|patch]
#
# Prints one word: a version (1.2.3, no "v"), "none" (nothing to release) or
# "breaking" (a breaking change: only a manual major release may ship it).
# An explicit level forces the bump (the manual workflow); the version itself
# is computed by git-cliff.
set -eu

level="${1:-}"
last="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
range="${last:+$last..}HEAD"

if [ "$(git rev-list --count "$range")" -eq 0 ]; then echo none; exit 0; fi

subjects="$(git log --format=%s "$range")"
if [ -z "$level" ]; then
    if printf '%s\n' "$subjects" | grep -Eq '^[a-z]+(\([^)]*\))?!:' ||
       git log --format=%B "$range" | grep -Eq '^BREAKING[ -]CHANGE'; then
        echo breaking; exit 0
    elif printf '%s\n' "$subjects" | grep -Eq '^feat(\([^)]*\))?:'; then level=minor
    elif printf '%s\n' "$subjects" | grep -Eq '^(fix|perf)(\([^)]*\))?:'; then level=patch
    else echo none; exit 0
    fi
fi

config="$(dirname "$0")/../cliff.toml"
git cliff --config "$config" --bump "$level" --bumped-version | sed 's/^v//'
