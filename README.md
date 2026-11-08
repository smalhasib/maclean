# Maclean

Maclean is a free, open-source disk space analyzer and cleaner for macOS, in the spirit of DaisyDisk. It scans a disk or folder, draws it as an interactive sunburst map, lets you collect what you want gone and delete it in one go, and finds caches, logs and leftovers you can safely clean.

Native Swift and SwiftUI, light and dark mode, keyboard friendly, no telemetry, MIT licensed.

## Features

- **Fast scanning:** scans whole disks or any folder, using all CPU cores. Stays on one disk, doesn't follow links, counts hard links and APFS clones once.
- **Sunburst map:** drill in and out of folders with a click, see sizes on hover, with a side list of the largest items. Small items are merged into "smaller objects" that you can expand.
- **Collector:** drag items from the map, the list or Finder into the collector (or press ⌘⌫). Collected items vanish from the map and their folders shrink, so you see the space you'll get back before deleting anything.
- **Safe delete:**
  - A 5-second countdown with Cancel.
  - Every item is re-checked right before it's removed, so anything changed or replaced since the scan is held back.
  - Links swapped in are never followed, and the delete never crosses onto another disk.
  - Items that need administrator rights are deleted after a single password prompt.
  - You can move items to the Trash instead.
- **Smart Clean:**
  - Checks for cleanable caches, logs, developer junk, project build output (`node_modules`, `target`, …), leftovers of removed apps, old installers and system logs and caches.
  - Lists them by category and tier for you to review. Nothing is deleted until you tick items and confirm.
  - A Skipped section says why each item found wasn't offered.
- **Protected locations:** system folders, your home folder, Maclean itself and personal data such as keychains, Mail, Messages and Photos are refused.
- **Command-line scanner:** `maclean-scan` prints a disk's size breakdown in Terminal.

## Install

Maclean needs macOS 14 Sonoma or later and runs natively on Apple silicon and Intel.

### Homebrew

```sh
brew tap smalhasib/maclean
brew trust smalhasib/maclean
brew install --cask maclean
```

`brew trust` is needed once on Homebrew versions that only load casks from taps you've trusted. The cask lives in [smalhasib/homebrew-maclean](https://github.com/smalhasib/homebrew-maclean). This installs `Maclean.app` in `/Applications` and the `maclean-scan` command. To update, run `brew upgrade --cask maclean`. To uninstall, run `brew uninstall --cask maclean`; add `--zap` to also remove its settings.

Maclean is signed ad hoc, not with an Apple Developer ID. The cask clears macOS's download quarantine flag on the installed app so it opens normally.

### Download

Download `Maclean-<version>.zip` from [Releases](https://github.com/smalhasib/maclean/releases), unzip it and move `Maclean.app` to Applications. Because the app isn't notarized, macOS blocks the first launch. Open it once with right-click › Open, or allow it in System Settings › Privacy & Security, or run:

```sh
xattr -dr com.apple.quarantine /Applications/Maclean.app
```

### Build from source

You only need the Command Line Tools (`xcode-select --install`); Xcode isn't required.

```sh
git clone https://github.com/smalhasib/maclean.git
cd maclean
scripts/build-app.sh && open .build/Maclean.app
```

## Getting started

1. **Grant Full Disk Access (recommended).** Without it, macOS hides folders such as Mail, Messages, parts of `~/Library` and other apps' data. Those show up as restricted, counted as empty, so totals come out low. Open System Settings › Privacy & Security › Full Disk Access, add Maclean, then relaunch it.
2. **Pick something to scan.** The start screen lists your disks and starred folders. Click a disk, or choose File › Scan Folder… (⌘O). Progress shows while it scans.
3. **Explore the map.**
   - Click a segment to enter a folder, and click the centre to go back up.
   - Hover over a segment to see its name and size; the side list follows.
   - Press Space to preview an item with Quick Look. Right-click for Show in Finder, Open in Terminal and Move to Collector.
4. **Collect and delete.** See below.

### Collector and delete

**Collecting.** Drag a chart segment, a list row or an item from Finder onto the collector bar at the bottom of the window. You can also:
- press ⌘⌫ on the hovered or selected item;
- choose Move to Collector from the context menu;
- use the Action menu: Move to Collector, Move All Items from Current Folder to Collector, or Remove All Items from Collector.

Collected items vanish from the chart and list, and their folders shrink to match. The bar shows the running total. Open the panel to see each item, remove one with ×, or drag a row back to the chart.

**Deleting.**
- Delete starts a 5-second countdown with a Cancel button, then deletes the items permanently.
- Items that need administrator rights, such as ones owned by root, are deleted in one batch after the standard macOS administrator password prompt.
- When it finishes, a summary lists what was deleted, what failed and why, and anything that changed since the scan. You can delete those anyway or leave them.

**Trash instead.** Turn on Settings › "Move to Trash instead of deleting permanently" to move items to the Trash. Items that need administrator rights to remove can't be moved to the Trash, so they stay collected with a note.

**What the collector refuses.**
- System locations such as `/System`, `/usr` apart from `/usr/local`, and `/Library` essentials.
- Your home folder and the folders that contain it.
- Maclean itself and the folders that contain it.
- Other protected paths.

It tells you why when you try.

### Smart Clean

Smart Clean looks for things that are safe to regenerate or are clearly leftovers, and lists them for review.
- It runs when the app launches. You can switch that off in Settings › Smart Clean.
- Run it any time with Action › Check for Cleanable Items (⇧⌘K).
- The result appears as a card under the disk list on the start screen. Click **Review…** to see the list.

**What it checks.**
- **User-level:**
  - app caches and logs;
  - browser caches (Safari, Chromium-based browsers, Firefox);
  - developer files: Xcode derived data, old device support, simulator caches, package-manager caches;
  - build leftovers in your projects;
  - old installers in Downloads;
  - saved window state;
  - leftovers of apps you've removed;
  - Mail attachment downloads;
  - the Trash.
- **System-wide:** system logs and caches, background services and helper tools whose program or app is gone, and old macOS installers.
- **Large data it only points at:** iOS backups, Docker and OrbStack data, Maven and Gradle caches, local AI models. These are shown for information only; use the map to review them.

**Three tiers.**
- **Safe** items are ticked by default.
- **Review** items are listed unticked.
- **Info** items have no checkbox.
- Items whose size or age couldn't be measured are never ticked.
- Project build folders are offered only when nothing in them is tracked by Git, they have no local changes, and the project isn't in use.

**The launch check never asks for a password and never deletes.** It only reads.
- Sizes of system items it can't read stay unknown until you choose Measure with administrator rights in the review, which asks for your password once.
- Without Full Disk Access it doesn't look in Downloads, the Trash, Mail's attachments or other apps' containers.
- It never searches Desktop, Documents or Downloads for projects, unless you add them in Settings.

**Skipped.** A collapsed Skipped section lists what was found but not offered, with the reason: the owning app is open, used recently, protected, needs Full Disk Access, tracked by Git, and so on. If Smart Clean can't tell whether an item is safe, it keeps it.

**Never clean this.** Right-click a row and choose Never clean this to hide it for good. You can take it off the list again in Settings › Smart Clean, which also has a switch per category and the folders searched for projects.

**Cleaning.**
- Clean confirms first, then deletes with the same engine as the collector: the same re-checks right before removing, and the same refusals.
- It follows the Trash setting, except that the Trash itself is always emptied permanently.
- System items are removed in one batch after a single administrator password prompt.
- An item whose app has been opened since the check is skipped.

### Keyboard shortcuts

| Action | Shortcut |
|---|---|
| Scan Folder… | ⌘O |
| Open in New Window | ⇧⌘N |
| Back / Forward | ⌘[ / ⌘] |
| Enter Folder / Enclosing Folder | ⌘↓ / ⌘↑ |
| Back to Disks | ⇧⌘D |
| Expand "smaller objects" | ⌘E |
| Rescan Current Folder / Rescan | ⌘R / ⇧⌘R |
| Preview | Space |
| Show in Finder | ⌥⌘R |
| Open in Terminal | ⌥⌘T |
| Move to Collector | ⌘⌫ |
| Check for Cleanable Items | ⇧⌘K |
| Settings | ⌘, |

### Settings

- **General:** "Open each scan in its own window", and "Move to Trash instead of deleting permanently" (off by default).
- **Smart Clean:** the launch check, a switch per category, the Never clean list, and extra folders to search for projects.

## maclean-scan (command line)

```sh
maclean-scan <path> [--out <file>] [--top <n>]
```

This prints the total size, the file count, the number of restricted (unreadable) folders, the elapsed time and the `--top` largest children (default 10). Live progress goes to stderr. `--out` writes the scan tree as an archive. With Homebrew it's on your PATH. From source, run `swift run -c release maclean-scan <path>`.

The scan doesn't cross into other disks, disk images or network mounts. Like DaisyDisk, it does descend into the other APFS volumes of the root's container. Run it from a terminal with Full Disk Access for complete results.

Exit codes:

| Code | Meaning |
|---|---|
| `0` | OK |
| `1` | Root unreadable |
| `2` | Usage error |
| `3` | `--out` write failed |

## Safety and privacy

- Nothing leaves your Mac: no analytics or accounts. The only network access is the update check against GitHub's releases API, plus the update download when you accept one. Switch automatic checks off in Settings.
- Deletion only happens after you collect items, or tick them in Smart Clean, and confirm.
- Administrator actions go through the bundled `maclean-scan` helper behind the standard macOS password prompt. The helper re-checks every item itself, refuses anything outside its rules, and verifies a fingerprint of the item list it was given.
- Smart Clean's rules and protected lists are Maclean's own. Nothing is copied from [mole](https://github.com/tw93/mole) (GPL-3.0), which inspired it.

## Development

```sh
swift build
swift test
```

`scripts/build-app.sh` assembles `.build/Maclean.app`. It signs ad hoc, or with `MACLEAN_SIGN_IDENTITY`; set `MACLEAN_UNIVERSAL=1` for an Apple silicon and Intel build. Design notes and plans are in `docs/superpowers/`, and manual test steps are in [docs/manual-checklist.md](docs/manual-checklist.md).

### Releasing

1. Bump `CFBundleShortVersionString` in `Resources/Info.plist`.
2. Run `scripts/package-release.sh`. It prints the zip path and its SHA-256.
3. Create the release: `gh release create v<version> .build/Maclean-<version>.zip`.
4. Update `version` and `sha256` in `Casks/maclean.rb` in [smalhasib/homebrew-maclean](https://github.com/smalhasib/homebrew-maclean), then commit and push. Homebrew picks it up on the next `brew update`.

Bug reports and pull requests are welcome: [Issues](https://github.com/smalhasib/maclean/issues).

## License

[MIT](LICENSE)
