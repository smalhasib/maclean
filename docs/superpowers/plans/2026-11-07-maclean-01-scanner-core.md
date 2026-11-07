# Maclean Plan 1 — Scanner Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A fast, correct, UI-free disk scanner (`MacleanCore`) plus a `maclean-scan` CLI that scans a path, prints a size summary, and can save the result in Maclean's binary tree format.

**Architecture:** One SwiftPM package. `MacleanCore` holds a compact struct-of-arrays `FileTree`, built by `FileTreeBuilder`. `DirectoryReader` wraps `getattrlistbulk`, and the parallel `Scanner` combines them. `TreeArchive` serializes the tree. The `maclean-scan` executable is a thin wrapper. No Xcode: the machine has Command Line Tools only, so everything builds with `swift build` / `swift test`.

**Tech Stack:** Swift 6.4 (language mode 6), SwiftPM, Swift Testing (`import Testing`), Darwin (`getattrlistbulk`, `openat`, `fstatfs`), UniformTypeIdentifiers.

**Spec:** `docs/superpowers/specs/2026-11-07-maclean-design.md` (§6.1–6.4, §5.12a packages, §5.4 hard-link markers). Research: `docs/research/daisydisk-guide-notes.md`.

**Plan series (each written after the previous one lands):** 1 Scanner core (this) → 2 App shell: start screen, sunburst, side list, navigation → 3 Collector, delete, context actions → 4 Hidden space, Full Disk Access, admin scan, scan cache, scan queueing and not-responding timeouts → 5 Settings, menus, shortcuts, packaging and release CI.

## Global Constraints

- Minimum macOS 14 (`platforms: [.macOS(.v14)]`), Swift language mode 6, Universal builds are a Plan 5 concern.
- Size metric is **allocated size on disk** (`ATTR_FILE_ALLOCSIZE`), never logical size (network-share logical size is Plan 4).
- Never cross mount points, except the startup-disk firmlink case (Task 4).
- Don't follow symlinks; a symlink counts as its own allocated size.
- Hard links: the first link seen counts; later links count 0 and carry `hardLinkExtra`. APFS clones: the same rule, keyed by clone id, flag `cloneExtra`.
- Inode and device are optional (0 = unknown) so a future cloud source can fill the same tree (spec §5.12).
- No dependencies outside the Apple SDK.
- Tests only ever touch temp directories under `FileManager.default.temporaryDirectory`. Nothing in this plan deletes user files.
- Commit messages: Conventional Commits.

## Review Focus

1. **Odd file names** (combining characters, emoji, newline, non-UTF-8-normalised bytes). `path(of:)` must reproduce the exact on-disk path, and the archive must round-trip it. Test in Task 2 and Task 5.
2. **Very deep nesting beyond PATH_MAX (1024)**. The scan must not fail; use `openat` relative to the parent fd, never full paths. Test in Task 4.
3. **Unreadable folders** (mode 000, TCC-protected). Mark them `restricted`, still list them with size 0, and carry on scanning. Test in Task 4.
4. **Symlink to a parent folder (loop)**. Don't follow it, and the scan terminates. Test in Task 4.
5. **Entries vanishing mid-scan** (ENOENT on open). Skip them silently. `DirectoryReader` maps them to `.notFound`; the scanner treats `.notFound` as "omit". Test in Task 3 and Task 4.

---

### Task 1: Package scaffold

**Files:**
- Create: `Package.swift`, `.gitignore` (`.build/`, `.swiftpm/`, `*.xcodeproj`, `.DS_Store`), `Sources/MacleanCore/MacleanCore.swift` (empty `public enum MacleanCore {}`), `Sources/maclean-scan/main.swift` (prints usage), `Tests/MacleanCoreTests/SmokeTests.swift`, `LICENSE` (MIT, copyright "2026 Maclean contributors").

**Interfaces:**
- Produces: library product `MacleanCore`, executable product `maclean-scan`, test target `MacleanCoreTests`.

- [ ] **Step 1: Write `Package.swift`**: tools version 6.0, `platforms: [.macOS(.v14)]`, targets `MacleanCore`, `maclean-scan` (depends on `MacleanCore`), and test target `MacleanCoreTests`.
- [ ] **Step 2: Smoke test** `@Test func packageBuilds() { #expect(Bool(true)) }`
- [ ] **Step 3: Run** `swift build && swift test`. Expected: build succeeds, 1 test passed.
- [ ] **Step 4: Commit** `chore: scaffold SwiftPM package`

---

### Task 2: `FileTree` + `FileTreeBuilder`

**Files:**
- Create: `Sources/MacleanCore/FileTree.swift`, `Sources/MacleanCore/FileTreeBuilder.swift`
- Test: `Tests/MacleanCoreTests/FileTreeTests.swift`

**Interfaces:**
- Produces:
```swift
public struct NodeID: Hashable, Sendable, Comparable { public let index: Int32 }
public struct NodeFlags: OptionSet, Sendable {   // rawValue: UInt16
  directory, symlink, package, restricted, hardLinkFirst, hardLinkExtra, cloneExtra
}
public final class FileTree: Sendable {
  public let rootPath: String          // absolute path of the scanned root
  public let scanDate: Date
  public var root: NodeID { get }      // always index 0
  public var count: Int { get }
  public func name(of: NodeID) -> String
  public func path(of: NodeID) -> String          // rootPath + "/" + names; root returns rootPath
  public func size(of: NodeID) -> Int64           // allocated bytes; for directories the subtree total
  public func flags(of: NodeID) -> NodeFlags
  public func parent(of: NodeID) -> NodeID?
  public func children(of: NodeID) -> [NodeID]    // sorted by size desc, then name asc
  public func inode(of: NodeID) -> UInt64         // 0 = unknown
  public func device(of: NodeID) -> Int32         // 0 = unknown
  public func fileCount(of: NodeID) -> Int64      // non-directory descendants (+1 if self is a file)
}
public final class FileTreeBuilder {
  public init(rootPath: String, rootInode: UInt64, rootDevice: Int32, scanDate: Date = .now)
  public var root: NodeID { get }
  @discardableResult
  public func add(parent: NodeID, name: String, size: Int64, flags: NodeFlags,
                  inode: UInt64, device: Int32) -> NodeID
  public func markRestricted(_ id: NodeID)
  public func finish() -> FileTree    // sums sizes bottom-up, sorts, makes children contiguous
}
```
- Storage (decided): struct-of-arrays with `parent: [Int32]`, `firstChild: [Int32]`, `childCount: [Int32]`, `size: [Int64]`, `fileCount: [Int64]`, `flags: [UInt16]`, `inode: [UInt64]`, `device: [Int32]`, `nameOffset: [UInt32]`, `nameLength: [UInt16]`, and one shared `names: [UInt8]` (raw file-system bytes, no normalisation). Target under 64 bytes per node including the average name. `finish()` renumbers nodes in BFS order so that each node's children occupy `firstChild ..< firstChild+childCount`, already sorted.

- [ ] **Step 1: Write failing tests**
```swift
@Test func sizesSumAndChildrenSortDescending() {
  let b = FileTreeBuilder(rootPath: "/r", rootInode: 1, rootDevice: 1)
  let a = b.add(parent: b.root, name: "a", size: 0, flags: .directory, inode: 2, device: 1)
  b.add(parent: a, name: "small", size: 10, flags: [], inode: 3, device: 1)
  b.add(parent: a, name: "big", size: 300, flags: [], inode: 4, device: 1)
  b.add(parent: b.root, name: "f", size: 50, flags: [], inode: 5, device: 1)
  let t = b.finish()
  #expect(t.size(of: t.root) == 360)
  #expect(t.children(of: t.root).map { t.name(of: $0) } == ["a", "f"])
  let aID = t.children(of: t.root)[0]
  #expect(t.children(of: aID).map { t.name(of: $0) } == ["big", "small"])
  #expect(t.path(of: t.children(of: aID)[0]) == "/r/a/big")
  #expect(t.fileCount(of: t.root) == 3)
  #expect(t.parent(of: aID) == t.root && t.parent(of: t.root) == nil)
}
@Test func equalSizesSortByName()   // "b"(5), "a"(5) → ["a","b"]
@Test func oddNamesRoundTripExactly() // name "cafe\u{301} 🎉\nx" → name(of:) == same string, path ends with it
@Test func restrictedFlagIsKept()     // markRestricted(dir) → flags contains .restricted
```
- [ ] **Step 2: Run** `swift test --filter FileTreeTests`. Expected: FAIL (types not defined).
- [ ] **Step 3: Implement** `FileTree` and `FileTreeBuilder` as specified above. The builder stages nodes in append order; `finish()` does the bottom-up sum (process indices in reverse append order, since parents are always appended before children), then the BFS renumbering with a stable sort (size desc, name bytes asc).
- [ ] **Step 4: Run** `swift test --filter FileTreeTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): add compact FileTree and builder`

---

### Task 3: `DirectoryReader` (getattrlistbulk)

**Files:**
- Create: `Sources/MacleanCore/DirectoryReader.swift`
- Test: `Tests/MacleanCoreTests/DirectoryReaderTests.swift`

**Interfaces:**
- Produces:
```swift
public enum EntryKind: Sendable { case file, directory, symlink, other }
public struct RawEntry: Sendable {
  public var name: String; public var kind: EntryKind
  public var inode: UInt64; public var device: Int32
  public var linkCount: UInt32; public var allocatedSize: Int64   // 0 for directories
  public var cloneID: UInt64; public var cloneRefCount: UInt32    // 0 when unsupported
}
public enum ReadError: Error, Equatable { case notFound, permissionDenied, notDirectory, other(Int32) }
public struct DirectoryHandle: ~Copyable { public let fd: Int32 }  // closes fd in deinit
public enum DirectoryReader {
  public static func open(path: String) throws(ReadError) -> DirectoryHandle
  public static func open(name: String, in parent: borrowing DirectoryHandle) throws(ReadError) -> DirectoryHandle  // openat, O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC
  public static func entries(of dir: borrowing DirectoryHandle) throws(ReadError) -> [RawEntry]
}
```
- Approach (decided): `getattrlistbulk` with `FSOPT_PACK_INVAL_ATTRS | FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW`. Request `ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID`, `ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE`, and forkattr `ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT`, with a 256 KB buffer. Parse each record in the fixed attribute order, honouring `returned_attrs` (a missing attribute is not present in the record). Map errno: ENOENT→`.notFound`, EACCES/EPERM→`.permissionDenied`, ENOTDIR→`.notDirectory`, everything else `.other(errno)`. Never return "." or "..".

- [ ] **Step 1: Write failing tests** (fixture helper `TempDir` in `Tests/MacleanCoreTests/TempDir.swift`: creates a unique temp dir, `file(_ path:, bytes:)`, `dir(_:)`, `symlink(_:to:)`, `hardlink(_:to:)`, removes everything in `deinit`, restoring permissions first)
```swift
@Test func listsFilesDirsAndSymlinks() throws {
  let t = TempDir(); t.file("a.bin", bytes: 10_000); t.dir("sub"); t.symlink("ln", to: "sub")
  let h = try DirectoryReader.open(path: t.path)
  let e = try DirectoryReader.entries(of: h).sorted { $0.name < $1.name }
  #expect(e.map(\.name) == ["a.bin", "ln", "sub"])
  #expect(e.map(\.kind) == [.file, .symlink, .directory])
  #expect(e[0].allocatedSize >= 10_000 && e[0].inode != 0 && e[0].linkCount == 1)
}
@Test func hardLinkReportsLinkCount()   // hardlink → both entries linkCount == 2, same inode
@Test func missingPathThrowsNotFound()  // open(path: t.path + "/nope") throws .notFound
@Test func unreadableDirThrowsPermissionDenied() // chmod 000 sub; open(name:"sub", in:) or entries throws .permissionDenied
@Test func readsManyEntries()           // 5_000 files → 5_000 entries (exercises multiple getattrlistbulk calls)
```
- [ ] **Step 2: Run** `swift test --filter DirectoryReaderTests`. Expected: FAIL.
- [ ] **Step 3: Implement** as described.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): add getattrlistbulk directory reader`

---

### Task 4: Parallel `Scanner`

**Files:**
- Create: `Sources/MacleanCore/Scanner.swift`, `Sources/MacleanCore/ScanBoundary.swift`, `Sources/MacleanCore/PackageDetector.swift`
- Test: `Tests/MacleanCoreTests/ScannerTests.swift`

**Interfaces:**
- Consumes: `FileTreeBuilder` (Task 2), `DirectoryReader` and `RawEntry` (Task 3).
- Produces:
```swift
public struct ScanProgress: Sendable { public var bytes: Int64; public var items: Int64; public var currentPath: String }
public struct ScanBoundary: Sendable {
  public var allowedDevices: Set<Int32>; public var skippedPaths: Set<String>
  public static func forRoot(_ path: String) -> ScanBoundary
}
public enum PackageDetector { public static func isPackage(name: String) -> Bool }  // per-extension cache
public enum Scanner {
  public static func scan(path: String,
                          progress: @Sendable (ScanProgress) -> Void = { _ in }) async throws -> FileTree
}
```
- Decisions:
  - **Boundary:** `forRoot` allows the root's device. When the root is `/`, it also allows the device of `/System/Volumes/Data` and adds `"/System/Volumes/Data"` to `skippedPaths`, so firmlinked `/Users`, `/Applications` and so on are scanned once, through their `/` paths, as in DaisyDisk's root view. Directories on any other device are added as 0-size directory nodes and are not descended.
  - **Parallelism:** a `withThrowingTaskGroup` work queue with at most `ProcessInfo.activeProcessorCount * 2` directories in flight. Each job opens its directory with `openat` from the parent's fd, so no full paths are needed (PATH_MAX safety), reads its entries, and returns them. A single consumer appends the entries to the builder (the builder is not thread-safe) and enqueues the child directories. Keep the parent fd open only until its children are opened; otherwise reopen by path from the nearest ancestor that is still open. *Implementer may choose the fd-lifetime strategy, but must pass the deep-nesting test and must not exceed `ulimit -n` (256 default).*
  - **Accounting:** hard links (`linkCount > 1`) are de-duplicated by `(device, inode)`; clones (`cloneRefCount > 1`) by `(device, cloneID)`. The first one seen gets its size and `hardLinkFirst`; later ones get size 0 and `hardLinkExtra`/`cloneExtra`.
  - **Errors:** a `.permissionDenied` directory becomes a node with `.restricted` and is not descended. `.notFound` entries are omitted. Any other per-directory error is treated as restricted. Only a root that can't be opened throws.
  - **Packages:** directories whose `PackageDetector.isPackage(name:)` is true (`UTType(filenameExtension:)?.conforms(to: .package)`, cached per lowercased extension) get `.package` and are still scanned fully.
  - **Progress:** at most every 100 ms. **Cancellation:** check `Task.isCancelled` per directory and throw `CancellationError`.

- [ ] **Step 1: Write failing tests**
```swift
@Test func totalsMatchFixture() async throws {
  let t = TempDir(); t.file("a/x", bytes: 8192); t.file("a/b/y", bytes: 4096); t.file("z", bytes: 4096)
  let tree = try await Scanner.scan(path: t.path)
  let expected = try ["a/x","a/b/y","z"].map { try allocSize(t.path + "/" + $0) }.reduce(0, +)
  #expect(tree.size(of: tree.root) == expected)
  #expect(tree.fileCount(of: tree.root) == 3)
}
@Test func hardLinksCountOnce()        // file 1 MB + hardlink → root size == one allocation; one node .hardLinkFirst, other .hardLinkExtra size 0
@Test func clonesCountOnce()           // `cp -c` 1 MB file (APFS temp dir) → second copy .cloneExtra size 0; skip with #require if cloneRefCount == 0 (non-APFS)
@Test func symlinkLoopIsNotFollowed()  // symlink "loop" → "." ; scan finishes, node has .symlink, no children
@Test func unreadableDirIsRestricted() // chmod 000 "secret" containing a file → node .restricted, size 0, scan succeeds
@Test func deepNestingBeyondPathMax()  // 300 nested dirs named "d123456789" + file at bottom → scan succeeds, fileCount == 1
@Test func packageIsFlagged()          // dir "Foo.app" → .package and .directory, children still scanned
@Test func boundaryForStartupDisk()    // ScanBoundary.forRoot("/") → skippedPaths contains "/System/Volumes/Data", allowedDevices.count == 2
@Test func cancellationThrows() async  // scan of 2_000-dir fixture inside a Task that is cancelled immediately → throws CancellationError
```
`allocSize(_:)` is a test helper using `stat().st_blocks * 512`.
- [ ] **Step 2: Run** `swift test --filter ScannerTests`. Expected: FAIL.
- [ ] **Step 3: Implement** `ScanBoundary`, `PackageDetector` and `Scanner` per the decisions above.
- [ ] **Step 4: Run** `swift test`. Expected: all tests PASS.
- [ ] **Step 5: Commit** `feat(core): add parallel scanner with link/clone dedupe`

---

### Task 5: `TreeArchive` (binary format)

**Files:**
- Create: `Sources/MacleanCore/TreeArchive.swift`
- Test: `Tests/MacleanCoreTests/TreeArchiveTests.swift`

**Interfaces:**
- Consumes: `FileTree` internals (same module; add an `internal init` taking the arrays).
- Produces:
```swift
public enum TreeArchive {
  public static func write(_ tree: FileTree, to url: URL) throws
  public static func read(from url: URL) throws -> FileTree
}
public enum ArchiveError: Error { case badMagic, unsupportedVersion(UInt32), truncated }
```
- Format (decided): magic `"MCLN"`, `version: UInt32 = 1`, node count, `scanDate` (Float64 seconds since 1970), rootPath (length-prefixed UTF-8), then each array as raw little-endian bytes in the field order of Task 2, then `names`. Writing goes to a temp file and is then renamed into place (atomic).

- [ ] **Step 1: Write failing tests:** `roundTripPreservesEverything` (scan a TempDir fixture including the odd name from Review Focus 1; write, read; every node's name/path/size/flags/inode/device/children equal), `rejectsWrongMagic` (throws `.badMagic`), `rejectsTruncatedFile` (first 20 bytes only → throws `.truncated`).
- [ ] **Step 2: Run** `swift test --filter TreeArchiveTests`. Expected: FAIL.
- [ ] **Step 3: Implement** per the format.
- [ ] **Step 4: Run** `swift test`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): add binary tree archive`

---

### Task 6: `maclean-scan` CLI + real-disk benchmark

**Files:**
- Modify: `Sources/maclean-scan/main.swift`
- Create: `README.md` (short: what Maclean is, status "in development", `swift build`/`swift test`, `maclean-scan` usage, MIT)

**Interfaces:**
- Consumes: `Scanner.scan`, `TreeArchive.write`, `FileTree` accessors.
- Produces the CLI contract used later by the admin scan (Plan 4):
  `maclean-scan <path> [--out <file>] [--top <n>]`. Exit codes: 0 = ok, 1 = root unreadable, 2 = usage error.

- [ ] **Step 1: Implement:** parse args by hand (no ArgumentParser dependency). Show live progress on stderr (`\r` line: GB scanned, items). On finish, print to stdout: total size (formatted with `ByteCountFormatter`, `.file` style), file count, number of restricted folders, elapsed seconds, and the top N children (default 10) with sizes. `--out` writes the archive.
- [ ] **Step 2: Verify on a fixture:** `swift run -c release maclean-scan Tests` → prints a total and the top entries, exit 0. `swift run maclean-scan /nope; echo $?` → `1`. `swift run maclean-scan; echo $?` → usage + `2`.
- [ ] **Step 3: Benchmark (read-only) on the startup disk:** `swift build -c release && time .build/release/maclean-scan / --top 8 --out .build/maclean-root.mcln`. Expected: finishes in under 60 s (DaisyDisk took ~30 s on this Mac). The total is within 5% of DaisyDisk's 417.2 GB scanned figure *if the terminal running it has Full Disk Access*; the top children are Users, System, opt, Applications, private, Library, in roughly the sizes DaisyDisk showed (305.8, 41.5, 14.4, 14.1, 8.2, 6.2 GB). Record the actual numbers in the commit body. If it is more than 5% off, investigate before committing: firmlink double-counting or missing `/System/Volumes/Data` content are the likely causes.
- [ ] **Step 4: Commit** `feat(cli): add maclean-scan with summary and archive output`, with the benchmark numbers in the body.
