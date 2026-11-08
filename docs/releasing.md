# Releasing

Releases are automatic. Commits follow [Conventional Commits](https://www.conventionalcommits.org/), and a push to `main` decides what ships:

| Commits since the last tag | Result |
|---|---|
| `feat:` | minor release (0.3.0 → 0.4.0) |
| `fix:` or `perf:` | patch release (0.3.0 → 0.3.1) |
| only `docs:`, `chore:`, `test:`, `ci:` … | nothing |
| a breaking change (`feat!:` or a `BREAKING CHANGE:` footer) | nothing automatic: start a **major** release by hand |

A pull request builds, tests and shows the release it would cause in the run summary. It never publishes, and it uses no secrets. With squash merges, the pull request title is the commit message, so make it a Conventional Commit.

## What a release does

`.github/workflows/release.yml`, on a macOS runner:

1. Tests, then asks `scripts/next-release.sh` for the version (git-cliff computes it; `cliff.toml` holds the rules).
2. Sets the version in `Resources/Info.plist`, bumps the build number, and regenerates `CHANGELOG.md`.
3. Builds the universal app, signs it with "Maclean Release", and signs the zip with the update key (`scripts/package-release.sh`).
4. Commits `chore(release): vX.Y.Z`, tags it, and pushes. Nothing is published before this succeeds.
5. Creates the GitHub release (zip, `.sig`, notes from the commits), then bumps the cask in [smalhasib/homebrew-maclean](https://github.com/smalhasib/homebrew-maclean).

If `main` moves while a release builds, the push fails and nothing is published; the next push to `main` releases again.

## Major releases

Actions › Release › Run workflow › level `major`.

## One-time setup

Done once on the machine that holds the signing certificate and update key:

1. `sh scripts/make-signing-cert.sh` creates the "Maclean Release" certificate (a stable signature keeps Full Disk Access across updates).
2. `swift scripts/update-key.swift generate ~/.config/maclean/update-key`, then put the printed public key in `Sources/MacleanCore/UpdateKey.swift`. Keep the key file private and backed up: installed apps only accept updates signed by it.
3. Export the certificate from Keychain Access as a `.p12`, then run `sh scripts/set-release-secrets.sh <file>.p12` and delete the `.p12`. It sets the repository secrets `SIGNING_P12_BASE64`, `SIGNING_P12_PASSWORD`, `UPDATE_KEY` and `TAP_DEPLOY_KEY` (a deploy key that can push to the tap repo only).

Anyone who can push to `main` can make this workflow sign and publish a release, so keep write access small. Moving to an Apple Developer ID later replaces the self-signed certificate and the quarantine workaround in the cask.

## Manual release

`scripts/package-release.sh` builds and signs on your Mac; then `gh release create vX.Y.Z .build/Maclean-X.Y.Z.zip .build/Maclean-X.Y.Z.zip.sig` and bump the cask by hand. The updater needs the `.sig` asset.
