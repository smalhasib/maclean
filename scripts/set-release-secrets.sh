#!/bin/sh
# One-time setup of the GitHub Actions secrets the Release workflow needs.
# Run it yourself, on the machine that holds the signing certificate:
#
#   sh scripts/set-release-secrets.sh <exported-certificate.p12>
#
# Export the certificate first: Keychain Access › login › My Certificates ›
# "Maclean Release" › right-click › Export… › Personal Information Exchange
# (.p12), with a password you choose. The .p12 holds the private key: delete it
# once this has run.
#
# Sets SIGNING_P12_BASE64, SIGNING_P12_PASSWORD, UPDATE_KEY and TAP_DEPLOY_KEY.
# TAP_DEPLOY_KEY is a fresh SSH key whose public half is added to the Homebrew
# tap repo as a write deploy key, so the workflow can push the cask and nothing else.
set -eu

repo="smalhasib/maclean"
tap="smalhasib/homebrew-maclean"
p12="${1:?usage: set-release-secrets.sh <exported-certificate.p12>}"
update_key="${MACLEAN_UPDATE_KEY:-$HOME/.config/maclean/update-key}"
[ -f "$p12" ] || { echo "No such file: $p12" >&2; exit 1; }
[ -f "$update_key" ] || { echo "No update key at $update_key." >&2; exit 1; }

printf 'Password you gave the .p12 export: '
stty -echo; read -r password; stty echo; echo
openssl pkcs12 -in "$p12" -passin "pass:$password" -nokeys -legacy 2>/dev/null | grep -q . ||
    openssl pkcs12 -in "$p12" -passin "pass:$password" -nokeys 2>/dev/null | grep -q . ||
    { echo "Can't open the .p12 with that password." >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
base64 < "$p12" | tr -d '\n' | gh secret set SIGNING_P12_BASE64 --repo "$repo"
printf '%s' "$password" | gh secret set SIGNING_P12_PASSWORD --repo "$repo"
gh secret set UPDATE_KEY --repo "$repo" < "$update_key"

ssh-keygen -q -t ed25519 -N '' -C "maclean release workflow" -f "$tmp/tap-key"
gh repo deploy-key add "$tmp/tap-key.pub" --repo "$tap" --allow-write --title "maclean release workflow"
gh secret set TAP_DEPLOY_KEY --repo "$repo" < "$tmp/tap-key"

echo "Done. Delete $p12 now."
