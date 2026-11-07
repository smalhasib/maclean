# Maclean

Maclean is an open-source, native macOS disk analyzer in the spirit of DaisyDisk.

**Status: in development.** The scanner core, a command-line scanner, the app and the collector with delete exist so far.

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

**Deleting.** Delete starts a 5-second countdown with a Cancel button, then deletes the items permanently. Items that need administrator rights (for example, ones owned by root) are deleted in one batch after the standard macOS administrator password prompt. When it finishes, a summary lists what was deleted, what failed and why, and anything that changed since the scan, which you can delete anyway or leave. Collect and uncollect are disabled while a delete runs, and Forget or Rescan wait for it.

**Trash instead.** Settings › "Move to Trash instead of deleting permanently" moves items to the Trash instead.

**What the collector refuses.** System locations (such as `/System`, `/usr` apart from `/usr/local`, and `/Library` essentials), your home folder and the folders that contain it, Maclean itself and the folders that contain it, and other protected paths. It tells you why when you try. Deletion also re-checks each item right before removing it and never crosses onto another disk.

## License

MIT
