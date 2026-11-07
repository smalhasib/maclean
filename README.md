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

Exit codes: `0` ok, `1` root unreadable, `2` usage error.

## License

MIT
