# Maclean

Maclean is an open-source, native macOS disk analyzer in the spirit of DaisyDisk.

**Status: in development.** Only the scanner core and a command-line scanner exist so far.

## Build and test

```sh
swift build
swift test
```

## maclean-scan

```sh
swift run -c release maclean-scan <path> [--out <file>] [--top <n>]
```

Scans `<path>`, prints the total size, file count, number of restricted (unreadable) folders,
elapsed time and the `--top` largest children (default 10) to stdout. Live progress goes to stderr.
`--out` writes the scan tree as an archive.

Run it from a terminal with Full Disk Access for complete results: without it, macOS (TCC)
blocks folders such as `~/Pictures` and parts of `~/Library`, which are then reported as restricted
and counted as empty, so totals come out lower than tools that have access (e.g. DaisyDisk).
File names are printed with control characters escaped (`\u{1B}`).

Exit codes: `0` ok, `1` root unreadable, `2` usage error, `3` output (`--out`) write failed.
Progress is shown on stderr only when stderr is a terminal.

## License

MIT
