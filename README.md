<p align="center">
  <img src="docs/icon.png" alt="Maclean" width="128">
</p>

<h1 align="center">Maclean</h1>

<p align="center">
  A free, open-source disk space analyzer and cleaner for macOS.<br>
  Scan a disk, see where the space went on an interactive map, and clear it out safely.<br>
  Native Swift, no telemetry, MIT licensed.<br>
  <a href="https://smalhasib.github.io/maclean/">Website</a> · <a href="https://github.com/smalhasib/maclean/releases">Releases</a>
</p>

## Install

Needs macOS 14 Sonoma or later (Apple silicon and Intel).

**Homebrew**

```sh
brew tap smalhasib/maclean
brew trust smalhasib/maclean
brew install --cask maclean
```

Update with `brew upgrade --cask maclean`.

**Disk image (DMG)**

1. Download `Maclean-<version>.dmg` from [Releases](https://github.com/smalhasib/maclean/releases) and open it.
2. Drag **Maclean** onto the **Applications** shortcut, then eject the disk image.
3. Open Maclean from Applications.

Maclean isn't notarized by Apple, so macOS may block the first launch ("Apple could not verify…"). To allow it, once:

- **macOS 15 or later:** try to open Maclean, then go to System Settings › Privacy & Security, scroll to Security, click **Open Anyway** next to Maclean, and confirm with your password.
- **macOS 14:** right-click Maclean in Applications and choose **Open**, then **Open** again.
- **Terminal, any version:** `xattr -dr com.apple.quarantine /Applications/Maclean.app`

Once it opens, updates install themselves from within Maclean. The zip on the same page works the same way.

**From source** (Command Line Tools only, no Xcode needed)

```sh
git clone https://github.com/smalhasib/maclean.git && cd maclean
scripts/build-app.sh && open .build/Maclean.app
```

## How to use

1. **Grant Full Disk Access** when Maclean asks, or macOS hides folders like Mail and Messages and totals come out low. Maclean asks again at launch until it's on. For folders only an administrator can open, it asks for your password once per scan; turn that off in Settings.
2. **Pick a disk or folder** on the start screen, or choose File › Scan Folder… (⌘O).
3. **Explore the map.** Click a segment to go in, the centre to go back out. Hover for sizes. Click the eye on a row (or right-click › Preview, or press Space) to see the file itself in its own window: images, video, audio, PDF, text and SVG, plus anything else Quick Look can open.
4. **Collect what you don't need.** Drag items to the collector bar (or press ⌘⌫). Folders shrink as you collect, so you see the space you'll get back before anything is deleted.
5. **Delete.** A 5-second countdown, with Cancel, then the items go. Everything is re-checked right before removal. Turn on Settings › Move to Trash to use the Trash instead.
6. **Or let Smart Clean find it.** It lists caches, logs, build output and leftovers of removed apps for you to review (⇧⌘K). Nothing is deleted until you tick items and confirm.

Maclean checks for updates once a day and installs signed releases. Choose Maclean › Check for Updates… to check now.

## Keyboard shortcuts

| Action | Shortcut |
|---|---|
| Scan Folder… | ⌘O |
| Open in New Window | ⇧⌘N |
| Back / Forward | ⌘[ / ⌘] |
| Enter Folder / Enclosing Folder | ⌘↓ / ⌘↑ |
| Back to Disks | ⇧⌘D |
| Expand "smaller objects" | ⌘E |
| Rescan Current Folder / Rescan | ⌘R / ⇧⌘R |
| Preview with Quick Look | Space |
| Show in Finder | ⌥⌘R |
| Open in Terminal | ⌥⌘T |
| Move to Collector | ⌘⌫ |
| Check for Cleanable Items | ⇧⌘K |
| Settings | ⌘, |

## Features

- Fast, parallel scans of whole disks or any folder; hard links and APFS clones counted once.
- Interactive sunburst map with a side list of the largest items, and a preview window for any file, to see what it is before you delete it.
- Collector to see the space you'll free before deleting.
- Safe delete: countdown, re-check before removal, never crosses disks or follows swapped links, optional Trash.
- Smart Clean for caches, logs, developer junk and app leftovers, with the reason for anything it skips.
- Protected locations (system folders, your home folder, keychains, Mail, Messages, Photos) can't be deleted.
- Administrator password only when needed, through the standard macOS dialog.
- Signed automatic updates from GitHub releases.
- `maclean-scan` command-line scanner, installed with Homebrew.
- Light and dark mode, keyboard friendly.
