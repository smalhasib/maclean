#!/bin/sh
# Runnable check for next-release.sh: builds a scratch repo and asserts the decision.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
git init -q . && git config user.email t@t && git config user.name t
git commit -q --allow-empty -m "feat: first" && git tag v0.2.0

fail=0
check() { # name expected [level]
    got="$(sh "$here/next-release.sh" ${3:-})"
    if [ "$got" = "$2" ]; then echo "ok   $1"; else echo "FAIL $1: expected $2, got $got"; fail=1; fi
}
add() { if [ $# -gt 1 ]; then git commit -q --allow-empty -m "$1" -m "$2"; else git commit -q --allow-empty -m "$1"; fi; }

check "no commits"       none
add "docs: readme";      check "docs only"        none
add "chore: tidy";       check "chore only"       none
add "fix: bug";          check "fix is a patch"   0.2.1
add "feat(ui): thing";   check "feat beats fix"   0.3.0
add "perf: faster";      check "feat still minor" 0.3.0
add "fix!: break it";    check "bang is breaking" breaking
check "forced major"     1.0.0 major
check "forced patch"     0.2.1 patch
git reset -q --hard v0.2.0
add "feat: x" "BREAKING CHANGE: gone"; check "footer is breaking" breaking
git reset -q --hard v0.2.0
add "chore(release): v0.2.1";          check "release commit alone" none
exit $fail
