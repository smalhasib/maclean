# Maclean: Full Disk Access guide, administrator reads, and auto-update (design)

Date: 2026-11-08. Builds on Plan 3a (collector and delete) and Plan 3b (Smart Clean), both merged. Mockups agreed in the brainstorm: `.superpowers/brainstorm/99464-1794117294/content/` (`fda-launch.html` option A, and `password-and-update-v3.html`).

## 1. Intent

The owner wants Maclean to deliver the best possible experience. A scan that silently misses folders, or a Smart Clean that leaves items as "size unknown", falls short of that.

macOS hides data from apps in two separate ways, and Maclean should actively ask for both permissions it needs:
- **Privacy protection (TCC):** Mail, Messages, Photos, parts of `~/Library` and other apps' data. Only **Full Disk Access** unlocks these, and macOS gives apps no way to request it with a prompt.
- **Ownership:** folders only root can open, such as other users' homes, `/private/var/root` and parts of `/Library`. Only the **administrator password** unlocks these.

A complete picture needs both.

The owner also wants Maclean to **update itself**, checking automatically and on demand.

## 2. Goals, non-goals, anti-goals

**Goals**
1. **Full Disk Access sheet:** every time Maclean opens without Full Disk Access, a sheet explains what scans will miss and guides the user to grant it. It keeps appearing on each launch until access is granted, or after it is revoked.
2. **Administrator reads:** when a scan, manual or Smart Clean, meets items only an administrator can read, Maclean asks for the administrator password with the standard macOS dialog and reads them. The scan map and the Smart Clean sizes then come out complete.
3. **The dialog says "Maclean wants to make changes."** Today it says "osascript wants to make changes."
4. **Auto-update:** Maclean checks GitHub for new releases automatically and on demand, shows what's new, and installs and relaunches with one click. Homebrew installs are left to Homebrew.

**Non-goals**
- Code signing with a Developer ID, notarization, or an `SMAppService` privileged helper. These are the right long-term answer, but they need a paid Apple Developer ID. They are noted under §8.
- Delta updates, beta channels, or update analytics.

**Anti-goals** (failures even if everything technically works)
- Asking for the password when nothing needs it, or more than once per scan or check.
- An updater that could install something the project didn't publish.
- Breaking Homebrew's view of the installed version.
- A Full Disk Access sheet that traps the user. "Continue without" always works.

## 3. Full Disk Access sheet (agreed: mockup A, a sheet you must answer)

- **Detection:** reuse the non-prompting probe that already exists (`LiveCleanProbes.hasFullDiskAccess`, which opens `~/Library/Application Support/com.apple.TCC/TCC.db` read-only). Move it somewhere both the app shell and Smart Clean can use.
- **When it shows:** at launch, over the start screen, whenever the probe says no. That includes after access is revoked. It never shows when access is granted.
- **Content** (copy as in the mockup):
  - a lock icon and the title "Give Maclean Full Disk Access";
  - one sentence on what is hidden without it;
  - three numbered steps;
  - a primary **Open System Settings** button, which opens `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`;
  - a **Continue without Full Disk Access** link.
- **After Continue:** the start screen shows a small persistent notice, "Scans will miss protected folders — Grant Access…", which reopens the sheet. Smart Clean already lists protected locations under Skipped.
- **Noticing the grant:**
  - When Maclean becomes active again, for example after the user returns from System Settings, it re-probes.
  - If access is now granted, the sheet or notice changes to "Full Disk Access is on. Relaunch Maclean to use it." with a **Relaunch** button. macOS applies the grant only to a new process.
  - Relaunch opens a new instance, then quits this one.
- **The launch Smart Clean check:** it may run behind the sheet, as today it skips protected locations without Full Disk Access. It's re-run after a relaunch.

## 4. Administrator reads

### 4.1 The dialog
- **Run in-process:** replace the `osascript` subprocess in `AdminRunner` with in-process `NSAppleScript` (`do shell script … with administrator privileges with prompt "<reason>"`). The system dialog then names Maclean, with Maclean's icon, and shows Maclean's one-sentence reason, as in the mockup.
- **Keep the security properties** of the current runner:
  - every argument is quoted with `quoted form of` and never interpolated;
  - the items or paths file and its SHA-256 still travel in argv;
  - a cancelled dialog maps to `AdminRunnerError.cancelled`;
  - there's no timeout.
- **Off the main thread:** `NSAppleScript` must not block the UI. Run it off the main thread and drain the output.
- **Reasons, one sentence per use:**
  - delete: existing behaviour;
  - "Maclean needs to read N folders that only an administrator can open.";
  - "Maclean needs to measure N system items for Smart Clean."

### 4.2 Manual scans
- **When it asks:** after a scan finishes and the tree has restricted folders (`.restricted` nodes), Maclean asks once, automatically, right away.
- **What it reads:** only the restricted folders, as root, using a new helper mode. The helper:
  - reads the list from a 0600 file with its SHA-256 in argv, like the delete and measure modes;
  - stays inside the scan's boundary (same disk, no symlinks);
  - writes each subtree as a tree archive (the existing `TreeArchive`) that the app can read.
- **What the app does with them:** it grafts the subtrees into the scan result, producing a new `FileTree`, so sizes, the chart and the list update in place. The collector and overlay carry over, the same way they do on rescan.
- **Cancel or failure:** the folders stay restricted. The result shows "N folders couldn't be read — Read with administrator rights", which asks again.
- **When it doesn't ask:**
  - the scan was cancelled;
  - there are no restricted folders;
  - the setting below is off.
- **Settings › General:** "Ask for the administrator password to read restricted folders", default **on**. *(My call: an off switch for people who never want the prompt.)*
- **Rescan:** a rescan that finds restricted folders asks again, once.

### 4.3 Smart Clean
- After a check, launch or on demand, finds `requiresAdmin` items it couldn't measure, Maclean runs the existing "Measure with administrator rights" automatically, with one prompt.
- The same setting governs it.
- Cancel leaves them "size unknown", and the review keeps the manual button.
- This **replaces** the Plan 3b rule "the launch check never asks for a password": the owner has asked for the prompt. The launch check still never deletes.

### 4.4 What root may read
- **Manual-scan mode:** only paths the request lists that are inside the scanned root, re-checked by the helper. These are reads only; nothing is modified.
- **Smart Clean measure:** unchanged (catalog system rules only).
- **Accepted residual:** a tampered request could make root report the sizes and names of root-only folders to the same user. The user is an administrator who just typed their password, so this is accepted. It's recorded with R31.

## 5. Auto-update

### 5.1 Checking
- **Source:** the GitHub Releases API, `https://api.github.com/repos/smalhasib/maclean/releases/latest`, with no token. The `tag_name` is `v<semver>`.
- **Compare:** against `CFBundleShortVersionString` by semantic version.
- **Automatic:**
  - at launch, at most once every 24 hours (store the last check time);
  - default on, as the "Check for updates automatically" box in the sheet and in Settings › General;
  - fails silently: no network means no message.
- **On demand:** Maclean › Check for Updates…. It shows "You're up to date" or an error.
- **Skip This Version:** stores the version and suppresses *automatic* prompts for it. Manual checks still show it.

### 5.2 The sheet (agreed: `password-and-update-v3.html`)
- The title "Maclean X is available" and "You have Y".
- "What's new", taken from the release body as plain text.
- The automatic-check box.
- Three buttons on one line: **Skip This Version**, **Later**, and **Install and Relaunch** as the default.
- The sheet is wide enough that no button wraps.

### 5.3 Installing
- **Download:** fetch the release asset `Maclean-<version>.zip` and its signature asset `Maclean-<version>.zip.sig`, with progress and Cancel.
- **Verify:** check the signature with an Ed25519 public key embedded in the app (CryptoKit `Curve25519.Signing`). Refuse anything that doesn't verify, and say so. A wrong checksum alone isn't enough, because GitHub serves both files.
  - *My call:* this is the same model Sparkle uses (EdDSA), without adding Sparkle as a dependency.
  - The private key lives with the owner, outside the repo. `scripts/package-release.sh` signs the zip when given the key, and the README's Releasing steps cover it.
- **Unpack:** unzip with `ditto` to a temp folder. Then check that the unpacked app's bundle id is `org.maclean.Maclean` and its version equals the release version.
- **Replace:**
  - Swap the running app's bundle: move the old one to the Trash, then move the new one into the same path.
  - When the parent folder isn't writable by the user, the swap goes through the root helper after the administrator dialog (§6a.2).
  - Clear the quarantine flag on the new bundle; it came from a verified download.
- **Relaunch:** start the new app with `open -n` after this process exits, using a tiny detached shell `sleep`-and-`open`, or `NSWorkspace` from a short-lived helper. Then quit.
- **Not during a delete:** an update never starts while a delete or Smart Clean run is in progress. "Install and Relaunch" waits, or says why it can't start yet.

### 5.4 Homebrew installs
- **Detection:** the app is a Homebrew cask install if `$(brew --prefix)/Caskroom/maclean` exists. Check the Caskroom under `/opt/homebrew` and `/usr/local`, without running brew.
- **What it does:** the check still runs, and the sheet replaces Install and Relaunch with a copyable `brew upgrade --cask maclean` and a **Copy Command** button. Maclean never replaces a Homebrew-managed bundle.
- **The cask** keeps `auto_updates` unset, because Homebrew owns updates for these installs.

### 5.5 Privacy
The README's "no network access" becomes: "The only network access is the update check against GitHub's releases API, plus the update download when you accept one. Switch automatic checks off in Settings."

## 6. Constraints
- macOS 14+, Swift 6, SwiftPM with Command Line Tools only, and **no third-party dependencies**. Hence CryptoKit rather than Sparkle.
- No test or check deletes real user files or runs the real updater against `/Applications`. Updater tests use a temp "installed app" and a test key pair.
- The root helper keeps every existing safety property. The new mode is read-only and follows the same file, SHA-256 and uid-0 rules.
- Commits follow Conventional Commits with no AI attribution. Never push without being asked. Releases are published only when the owner asks.

## 6a. Decisions made after the builder check (designer's calls)
1. **Root versus privacy-protected folders.**
   - A restricted folder can be blocked by ownership or by TCC, and root may still be refused on TCC folders when Maclean has no Full Disk Access.
   - Maclean asks whenever restricted folders exist. After the root read it reports what's still unreadable, as "N folders still need Full Disk Access", with **Grant Access…**.
   - The first plan task is a spike on a real Mac. It records what root can read with and without Full Disk Access when the dialog runs in-process.
   - If the spike shows root never helps with TCC folders, skip folders under known TCC locations when counting what to ask about.
2. **Privileged swap (owner's decision, replacing "no privileged swap").**
   - If the user can't replace the app's bundle, Maclean asks for the administrator password with the reason "Maclean needs your password to update itself.". The root helper then installs the update in a new `install-update` mode.
   - Before writing, the helper re-checks everything itself:
     - The zip and its signature arrive as 0600 files whose SHA-256 is in argv.
     - It verifies the Ed25519 signature with the public key compiled into MacleanCore.
     - It unzips into its own root-owned 0700 temp directory.
     - It checks that the bundle id is `org.maclean.Maclean` and that the version matches the request.
     - The target must be an existing bundle whose Info.plist bundle id is `org.maclean.Maclean`, at the path the request names, and that path must end in `.app`.
     - It renames the old bundle aside, moves the new one in, then removes the old one, restoring it if the move fails.
   - It writes nowhere else.
   - Cancel leaves the app untouched, and the sheet offers **Download** as a fallback.
3. **Prompt order: one coordinator.**
   - At launch: the Full Disk Access sheet first, then the update sheet, then any administrator dialog. Each waits until nothing is on screen above it.
   - Only one administrator dialog shows at a time. A scan read and a Smart Clean measure that are both waiting share one dialog: one helper call with both lists, and both reasons in one sentence.
   - On a Relaunch after granting Full Disk Access, this order starts over.
4. **Signing key and the first signed release.**
   - The plan includes a script that generates the Ed25519 key pair. The public key is embedded as base64. The private key is kept by the owner outside the repo: a file path or Keychain item passed to `package-release.sh`.
   - The signature asset is the raw 64-byte signature in base64, named `Maclean-<version>.zip.sig`.
   - 0.2.0 has no updater, so moving to the first updating release (0.3.0) is manual or via `brew upgrade`. The release notes say so.
5. **Root scan output.**
   - One archive per restricted folder, written by root into a fresh 0700 directory that the app creates and passes in. Root `chown`s the archives to the requesting user's uid, which is passed in argv and checked against the directory's owner. The app deletes the directory afterwards.
   - The boundary is rebuilt by the helper with `ScanBoundary.forRoot` of the scan root, as `--delete` rebuilds mounts, and it is read recursively.
6. **Homebrew detection:** require both that the Caskroom entry exists and that the running bundle's path is `/Applications/Maclean.app`, the cask's target. Any other copy self-updates.

7. **Stable code signing (owner's decision: a self-signed certificate).**
   - macOS ties Full Disk Access to the app's code signature. Ad-hoc builds change identity every build, so updates would silently revoke the grant.
   - The plan adds `scripts/make-signing-cert.sh`, which creates a self-signed code-signing certificate named "Maclean Release" in the owner's login Keychain once.
   - `package-release.sh` signs release builds with it through `MACLEAN_SIGN_IDENTITY` (`build-app.sh` already supports this). The certificate and its private key stay in the owner's Keychain, never in the repo.
   - Developer builds may stay ad hoc.
   - This is not a Developer ID: the quarantine handling in §5.3 and the cask stays. The README's Releasing steps are updated.
   - The manual checklist verifies that Full Disk Access survives an update from one release to the next.

## 7. Left to the builder
- How subtrees are grafted into `FileTree` (rebuild, or an overlay), as long as the chart and list read one consistent tree and the collector carries over.
- How the relaunch is implemented.
- Exact layouts within the agreed mockups.
- How to split this into tasks.

## 8. Later (recorded, not built)
With a Developer ID:
- notarize the app, so the quarantine workaround and the Homebrew postflight step go away;
- move administrator actions to an `SMAppService` privileged helper using Authorization Services;
- consider the self-declared `--context` (R31) closed at that point.
