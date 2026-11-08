# Maclean

Maclean is an open-source, native macOS disk analyzer in the spirit of DaisyDisk.

**Status: in development.** The scanner core, a command-line scanner, the app, the collector with delete and Smart Clean exist so far.

## Build and test

```sh
swift build
swift test
```

## Run the app

```sh
swift run Maclean
```

or build an app bundle (signed ad hoc, or with `MACLEAN_SIGN_IDENTITY`) and open it:

```sh
scripts/build-app.sh && open .build/Maclean.app
```

Both work with the Command Line Tools alone; Xcode isn't needed.

## maclean-scan

```sh
swift run -c release maclean-scan <path> [--out <file>] [--top <n>]
```

Scans `<path>`, prints the total size, file count, number of restricted (unreadable) folders,
elapsed time and the `--top` largest children (default 10) to stdout. Live progress goes to stderr.
`--out` writes the scan tree as an archive.

The scan doesn't cross into other disks, disk images or network mounts, but does descend into the other APFS volumes of the root's container (Preboot, VM, Update, Recovery) as DaisyDisk does, skipping /System/Volumes/Data (reached via firmlinks), Preboot's cryptex grafts, and APFS snapshot mounts.

Run it from a terminal with Full Disk Access for complete results: without it, macOS (TCC)
blocks folders such as `~/Pictures` and parts of `~/Library`, which are then reported as restricted
and counted as empty, so totals come out lower than tools that have access (e.g. DaisyDisk).
File names are printed with control characters escaped (`\u{1B}`).

Exit codes: `0` ok, `1` root unreadable, `2` usage error, `3` output (`--out`) write failed.
Progress is shown on stderr only when stderr is a terminal.

## Collector and Delete

Collect the items you want gone, then delete them in one go.

**Collecting.** Drag a chart segment, a list row or an item from Finder onto the collector bar at the bottom of the window. You can also press ⌘⌫ (on the hovered or selected item), choose Move to Collector from the context menu, or use the Action menu (Move to Collector, Move All Items from Current Folder to Collector, Remove All Items from Collector). Collected items vanish from the chart and list and their folders shrink to match. The bar shows the running total; open the panel to see each item, remove one with ×, or drag a row back to the chart.

**Deleting.** Delete starts a 5-second countdown with a Cancel button, then deletes the items permanently. Items that need administrator rights (for example, ones owned by root) are deleted in one batch after the standard macOS administrator password prompt. When it finishes, a summary lists what was deleted, what failed and why, and anything that changed since the scan, which you can delete anyway or leave. Collect and uncollect are disabled from the countdown until you close the summary. Forget during the countdown cancels the delete (nothing is deleted); Forget while a delete runs is refused. Rescan does nothing until the summary is closed. When deleting permanently, folders with contents you can't read (for example a root-only subfolder) go straight to the administrator step, which deletes them as a whole once their readable part checks out unchanged.

**Trash instead.** Settings › "Move to Trash instead of deleting permanently" moves items to the Trash instead. Items that need administrator rights to remove (for example, ones owned by root in a folder you can't write to) can't be moved to the Trash: they stay collected with a note. A folder with unreadable contents can still be moved when you can write to the folder it is in.

**What the collector refuses.** System locations (such as `/System`, `/usr` apart from `/usr/local`, and `/Library` essentials), your home folder and the folders that contain it, Maclean itself and the folders that contain it, and other protected paths. It tells you why when you try. Deletion also re-checks each item right before removing it and never crosses onto another disk.

## Smart Clean

Smart Clean looks for things that are safe to regenerate or are clearly leftovers, and lists them for review. It runs a check when the app launches (switch it off in Settings › Smart Clean) and on demand with Action › Check for Cleanable Items (⇧⌘K). The result appears as a card under the disk list on the start screen.

**What it checks.**
- *User-level:* app caches and logs, browser caches (Safari, Chromium-based browsers, Firefox), developer files (Xcode derived data, old device support, simulator caches and logs, package-manager caches), build leftovers in your projects (such as `node_modules`, `target`, `build`), old installers in Downloads, saved window state, leftovers of apps you've removed, Mail attachments Mail saved and the Trash.
- *System-wide:* system logs and caches, launch services and helper tools whose program or app is gone, and old macOS installers.
- *Large data it only points at:* iOS backups, Docker and OrbStack data, Maven and Gradle caches, local AI models and similar. These are shown for information with no checkbox, and Smart Clean never deletes them; use the map to review them.

**Three tiers.** *Safe* items are ticked by default, *Review* items are listed unticked, and *Info* items have no checkbox. Items whose size or age couldn't be measured are never ticked. Project folders appear grouped by project, and only when the project has no Git repository inside the item, nothing in it is tracked by Git, nothing in it has local changes, and it isn't in use.

**The launch check never asks for a password and never deletes.** It only reads. Sizes of system items it can't read stay unknown until you choose Measure with administrator rights in the review, which asks for your password once. Cancel the prompt and those items stay listed as "administrator password not given".

**Skipped.** Anything found but not offered goes under a collapsed Skipped section with the reason: the owning app is open, used recently, protected, needs Full Disk Access, tracked by Git, and so on. If Smart Clean can't tell whether an item is safe, it keeps it.

**Never clean this.** The row context menu hides a row and adds it to a list in Settings › Smart Clean, where you can take it off again. Settings also has a switch per category and the folders searched for projects.

**Cleaning.** Clean confirms first, then deletes with the same engine as the collector (the same re-checks right before removing, the same refusals), using the Trash setting, except for the Trash itself, which is always deleted permanently. Items in system locations are removed in one batch after a single administrator password prompt. Apps are re-checked when you clean, and an item whose owner has opened it since is skipped. The result is a summary, and the map shrinks to match.

Smart Clean's rules and protected lists are Maclean's own; nothing is copied from [mole](https://github.com/tw93/mole) (GPL-3.0).

## License

MIT
