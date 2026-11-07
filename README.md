# Maclean

Maclean is an open-source, native macOS disk analyzer in the spirit of DaisyDisk.

**Status: in development.** The scanner core, a command-line scanner and the start of the app exist so far.

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

## License

MIT
