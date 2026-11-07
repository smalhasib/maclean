# Maclean Plan 1b — Scanner Follow-ups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the scanner count what DaisyDisk counts (the other APFS volumes in the startup container), use at most ~100 B of memory per node at peak, and keep blocking disk reads off Swift's shared thread pool with a process-wide file-descriptor budget, before the app (Plan 2) builds on it.

**Architecture:** Three changes to `MacleanCore`. `ScanBoundary` learns which mount points belong to the root's APFS container and may be entered. `FileTreeBuilder.finish()` permutes its staging arrays in place, and `FileTree` drops two stored columns. `Scanner` runs directory reads on a dedicated dispatch queue and draws its fd allowance from a shared `FDBudget`.

**Tech Stack:** Swift 6.4 (language mode 6), SwiftPM with Command Line Tools only, Swift Testing, Darwin (`getmntinfo`, `statfs`), Dispatch.

**Spec:** `docs/superpowers/specs/2026-11-07-maclean-design.md` (§6.2 scanner, §6.3 tree model). Background: "Outcome and follow-ups" in `docs/superpowers/plans/2026-11-07-maclean-01-scanner-core.md`.

## Global Constraints

- Minimum macOS 14, Swift language mode 6, no dependencies outside the Apple SDK.
- Size metric stays allocated size on disk. Hard links and clones are still counted once.
- Never descend into other disks, disk images, or network mounts; never open a mount point that isn't descendable (no automount triggers).
- `/System/Volumes/Data` is still skipped wherever it lies inside the root (it's reached through firmlinks).
- Tests only touch temp directories. Manual checks are read-only scans and write only inside `.build/`.
- Plain `swift test` sometimes fails with "plugin for module 'TestingMacros' not found" (Command Line Tools bug). Then run: `swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`
- Commit messages: Conventional Commits, no AI attribution lines.
- **Memory targets (replace the spec's "<64 B/node"):** steady-state `FileTree` storage ≤ 40 B/node + name bytes; peak during `finish()` ≤ 100 B/node including names. Owner-visible check: peak RSS of `maclean-scan /` ≤ 650 MB (was 1.13 GB for 4.3M nodes).

## Review Focus

1. **A same-container volume that is partly unreadable** (VM swap files are root-only). It must become restricted nodes inside the volume, and the scan carries on. Test in Task 1.
2. **External disks, disk images and network shares under `/Volumes`** are still not entered when scanning `/`. Only the root's APFS container is. Test in Task 1.
3. **A mount point given as the scan root** (e.g. `/System/Volumes/Preboot`) scans normally: the root is never treated as a boundary. Test in Task 1.
4. **Two scans at once** (the app will scan several folders) share the fd budget: both finish, with no folders wrongly marked restricted. Test in Task 3.
5. **Cancelling while reads are queued** on the dispatch queue. Every continuation resumes, the scan throws `CancellationError` promptly, and no fds leak. Test in Task 3.

---

### Task 1: Descend into same-container APFS volumes

**Files:**
- Modify: `Sources/MacleanCore/ScanBoundary.swift`, `Sources/MacleanCore/Scanner.swift`
- Test: `Tests/MacleanCoreTests/ScannerTests.swift`

**Interfaces:**
- Consumes: `RawEntry.isMountPoint`, `NodeFlags.mountPoint`, `Walk.add(_:in:)`, and the skip-path depth logic (`maxSkipDepth`) in `Scanner.swift`.
- Produces:
```swift
public struct ScanBoundary: Sendable {
  public var allowedDevices: Set<Int32>
  public var skippedPaths: Set<String>
  /// Canonical paths of mount points the scan may enter.
  public var descendableMounts: Set<String>        // new, default []
  public init(allowedDevices: Set<Int32>, skippedPaths: Set<String> = [], descendableMounts: Set<String> = [])
  public static func forRoot(_ path: String) -> ScanBoundary
}
struct MountInfo: Sendable { let path: String; let device: Int32; let source: String; let fsType: String }
extension ScanBoundary {
  static func mounts() -> [MountInfo]                       // getmntinfo(MNT_NOWAIT)
  static func apfsContainer(ofSource source: String) -> String?  // "/dev/disk3s1s1" → "disk3", else nil
}
```
- Decisions:
  - `forRoot` finds the root's own mount: the entry of `mounts()` with the longest path that is a prefix of the canonical root. When that mount is APFS, every other APFS mount from the same container (same `apfsContainer`), other than `/System/Volumes/Data`, whose path lies **strictly inside** the root, goes into `descendableMounts`, and its device goes into `allowedDevices`. On this Mac that means `/System/Volumes/Preboot`, `/System/Volumes/VM`, `/System/Volumes/Update` and `/Volumes/Recovery` when the root is `/`. Mounts from other containers or disks are never added.
  - In `Walk.add`, a mount-point directory whose joined path is in `descendableMounts` is pushed like a normal directory, but its node still gets `.mountPoint`, so Plan 3 can refuse to collect it as a volume root. Any other mount point stays a 0-size `.mountPoint` node and is never opened. `maxSkipDepth` must also cover the depth of `descendableMounts` paths, so their paths get built and compared.
  - In `handle(token:outcome:)`, a directory pushed this way keeps `.mountPoint` when it becomes a node. Carry the flag through the `Pending`/`addDirectory` path.
  - The root itself is never a boundary, even when it is a mount point (Review Focus 3).

- [ ] **Step 1: Write failing tests**
```swift
@Test func containerParsing() {
  #expect(ScanBoundary.apfsContainer(ofSource: "/dev/disk3s1s1") == "disk3")
  #expect(ScanBoundary.apfsContainer(ofSource: "/dev/disk3s5") == "disk3")
  #expect(ScanBoundary.apfsContainer(ofSource: "/dev/disk12s2") == "disk12")
  #expect(ScanBoundary.apfsContainer(ofSource: "map auto_home") == nil)
  #expect(ScanBoundary.apfsContainer(ofSource: "//user@server/share") == nil)
}
@Test(.enabled(if: FileManager.default.fileExists(atPath: "/System/Volumes/Preboot")))
func startupRootDescendsSameContainerVolumes() {
  let b = ScanBoundary.forRoot("/")
  #expect(b.descendableMounts.contains("/System/Volumes/Preboot"))
  #expect(!b.descendableMounts.contains("/System/Volumes/Data"))
  #expect(b.skippedPaths.contains("/System/Volumes/Data"))
  #expect(b.descendableMounts.allSatisfy { ScanBoundary.mounts().first(where: { m in m.path == $0 })?.fsType == "apfs" })
}
@Test func tempRootHasNoDescendableMounts() {   // TempDir root: descendableMounts.isEmpty
}
@Test(.enabled(if: FileManager.default.fileExists(atPath: "/System/Volumes/Preboot")))
func mountPointRootScansNormally() async throws {
  // ScanBoundary.forRoot("/System/Volumes/Preboot").allowedDevices contains that volume's device;
  // the scan of it (may be partly restricted) returns a tree whose root is not .mountPoint and has children.
}
@Test func nonDescendableMountStaysClosed()      // existing mountPointIsFlaggedAndNotDescended keeps passing unchanged
```
- [ ] **Step 2: Run** `swift test --filter ScannerTests`. Expected: the new tests FAIL (no `descendableMounts`/`apfsContainer`).
- [ ] **Step 3: Implement** `mounts()`, `apfsContainer(ofSource:)`, the `forRoot` additions, and the `Walk` changes as decided.
- [ ] **Step 4: Run** `swift test`. Expected: all PASS.
- [ ] **Step 5: Manual read-only check:** `swift build -c release && .build/release/maclean-scan /System --top 5`. Expected: a total around 40 GB (was 29.1 GB), with `Volumes` among the children. Also `.build/release/maclean-scan /Volumes --top 5` lists `Recovery` (about 1.6 GB, if mounted). Record both outputs in the commit body.
- [ ] **Step 6: Commit** `feat(core): descend same-container APFS volumes like DaisyDisk`

---

### Task 2: Cut tree memory

**Files:**
- Modify: `Sources/MacleanCore/FileTree.swift`, `Sources/MacleanCore/FileTreeBuilder.swift`, `Sources/MacleanCore/TreeArchive.swift`
- Test: `Tests/MacleanCoreTests/FileTreeTests.swift`, `Tests/MacleanCoreTests/TreeArchiveTests.swift`

**Interfaces:**
- Consumes: the existing `FileTree` public API (unchanged for callers).
- Produces:
  - `FileTree` stored columns become `parents, firstChild, childCount: [Int32]`, `sizes: [Int64]`, `flagBits: [UInt16]`, `inodes: [UInt64]`, `devices: [Int32]`, `nameOffset: [UInt32]` (count n + 1, a sentinel at the end), and `names: [UInt8]` **in BFS node order**. That is 38 B/node + names. `nameLength` and `fileCounts` are no longer stored.
  - `public func fileCount(of:) -> Int64` keeps its signature and is now computed by walking the subtree. It is O(subtree), and the doc comment says so.
  - `var storageBytes: Int { get }` (internal) is the sum of every column's `count * MemoryLayout<Element>.stride`, plus the names.
  - `TreeArchive` format **version 2**: the same header, then the columns above in that order, then the names. Reading version 1 throws `.unsupportedVersion(1)`, since no v1 caches exist yet.
- Decisions:
  - `finish()` must not hold a full second copy of every column. Sum sizes bottom-up in place. Compute the BFS `order` (and the `counts`/`grouped` child lists, freed as soon as `order` exists). Then **permute one column at a time** into BFS order, so the old column is released before the next is permuted. Rebuild `names` into BFS order while rebuilding `nameOffset`. The peak target is ≤ 100 B/node with names (Global Constraints).
  - The sort rule is unchanged: size descending, then name bytes ascending.

- [ ] **Step 1: Write failing tests**
```swift
@Test func steadyStateIsCompact() {
  let b = FileTreeBuilder(rootPath: "/r", rootInode: 1, rootDevice: 1)
  for i in 0..<100_000 { b.add(parent: b.root, name: String(format: "f%09d", i), size: Int64(i), flags: [], inode: UInt64(i + 2), device: 1) }
  let t = b.finish()
  #expect(Double(t.storageBytes) / Double(t.count) <= 40 + 10 + 1)   // 38 B columns + 10-byte names (+ sentinel slack)
}
@Test func fileCountIsComputed()        // existing fileCount expectations still hold (root == 3 in sizesSumAndChildrenSortDescending)
@Test func namesAreInBFSOrder()          // after finish, nameOffset is non-decreasing and name(of:) round-trips byte-exactly for a 3-level tree whose append order differs from BFS order
@Test func archiveV1IsRejected()         // a buffer with version 1 → throws .unsupportedVersion(1)
```
Also update the TreeArchive corruption tests' byte offsets to the v2 layout (the column order changes).
- [ ] **Step 2: Run** `swift test --filter "FileTreeTests|TreeArchiveTests"`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement** the column changes, the in-place `finish()`, the computed `fileCount`, `storageBytes`, and archive v2 (with the same structural validation as v1, plus: `nameOffset` is non-decreasing, `nameOffset[0] == 0` and `nameOffset[n] == names.count`).
- [ ] **Step 4: Run** `swift test`. Expected: all PASS.
- [ ] **Step 5: Manual read-only check:** `swift build -c release && /usr/bin/time -l .build/release/maclean-scan ~ --top 3 --out .build/home.mcln`. Record "maximum resident set size" and the node count (from a one-off debug print or `TreeArchive.read(...).count`) in the commit body. Expected: RSS ≤ 150 B × node count + 100 MB.
- [ ] **Step 6: Commit** `perf(core): permute tree columns in place and drop stored counts`

---

### Task 3: Reads off the cooperative pool, shared fd budget

**Files:**
- Create: `Sources/MacleanCore/FDBudget.swift`
- Modify: `Sources/MacleanCore/Scanner.swift`
- Test: `Tests/MacleanCoreTests/ScannerTests.swift`

**Interfaces:**
- Consumes: `Scanner.read(anchor:path:allowed:)`, and `Walk.maxInFlight`/`maxRetained` (now taken from a budget grant).
- Produces:
```swift
final class FDBudget: Sendable {                 // lock-protected (Mutex / OSAllocatedUnfairLock)
  init(limit: Int)
  static let shared: FDBudget                    // limit = RLIMIT_NOFILE soft limit / 2
  struct Grant: Sendable { let inFlight: Int; let retained: Int }
  func acquire(desiredInFlight: Int, desiredRetained: Int) -> Grant   // never below inFlight 2, retained 4
  func release(_ grant: Grant)
  var highWater: Int { get }                     // max fds ever granted at once (for tests)
}
extension Scanner {
  static func scan(path: String, boundary: ScanBoundary, budget: FDBudget,
                   progress: @Sendable (ScanProgress) -> Void) async throws -> FileTree   // internal; public overloads pass .shared
}
```
- Decisions:
  - **Reads:** run `read(...)` on one private concurrent `DispatchQueue` (`label: "maclean.scan.io"`, QoS `.utility`), bridged with `withCheckedContinuation` inside the task-group child. In-flight work is already bounded by the grant, so GCD can't over-spawn threads. Cancellation: `read` already returns `.failed(.other(ECANCELED))` when the task is cancelled; the queued closure must check a cancellation flag captured from the task (e.g. via `withTaskCancellationHandler` setting an atomic flag), so queued reads return immediately.
  - **Budget:** a grant costs `2 × inFlight + retained` fds. `acquire` gives the desired amounts if they fit. Otherwise it scales both down to what's left, but never below the floor (2 in flight, 4 retained), accepting a small overshoot rather than refusing to scan. `release` happens in a `defer` around the scan (success, throw, or cancel).

- [ ] **Step 1: Write failing tests**
```swift
@Test func concurrentScansShareSmallBudget() async throws {
  let budget = FDBudget(limit: 24)
  let a = TempDir(); makeDeepAndWide(a)  // reuse the deepAndWideExceedsFdBudget fixture builder
  let b = TempDir(); makeDeepAndWide(b)
  defer { withExtendedLifetime((a, b)) {} }
  async let ta = Scanner.scan(path: a.path, boundary: .forRoot(a.path), budget: budget, progress: { _ in })
  async let tb = Scanner.scan(path: b.path, boundary: .forRoot(b.path), budget: budget, progress: { _ in })
  let (x, y) = try await (ta, tb)
  #expect(restrictedCount(x) == 0 && restrictedCount(y) == 0)
  #expect(x.fileCount(of: x.root) == y.fileCount(of: y.root))
  #expect(budget.highWater <= 24 + 8)    // floor overshoot allowed for the second scan
}
@Test func budgetIsReleasedAfterCancel() async   // cancel a scan of a 2_000-dir fixture from its progress callback; it throws CancellationError; afterwards budget can grant the full desired amount again
```
(That reads no longer run on the cooperative pool is checked by review of the diff, not by a test: a timing test would pass against the old code too.)
- [ ] **Step 2: Run** `swift test --filter ScannerTests`. Expected: FAIL (`FDBudget` undefined).
- [ ] **Step 3: Implement** `FDBudget` and the scanner changes as decided.
- [ ] **Step 4: Run** `swift test`. Expected: all PASS.
- [ ] **Step 5: Manual read-only check:** `swift build -c release && time .build/release/maclean-scan / --top 3`. Expected: no slower than before (~25–28 s without sudo).
- [ ] **Step 6: Commit** `perf(core): run scan reads off the cooperative pool with shared fd budget`

---

## Owner verification (after Task 3; needs a terminal with Full Disk Access)

```bash
cd ~/Work/maclean && swift build -c release && /usr/bin/time -l sudo .build/release/maclean-scan / --top 8
```
Expected: System ≈ 41.5 GB, `Volumes` present (≈ 1.6 GB with Recovery mounted), the total within about 2% of DaisyDisk's visible 392.8 GB, under 30 s, and "maximum resident set size" ≤ 650 MB.

---

## Outcome and follow-ups (recorded after execution)

Built on branch `feat/scanner-followups`; 72 tests pass. Read-only `/` scan without sudo: 27.5 s, peak RSS 448 MB (was 1.13 GB), System 41.55 GB (DaisyDisk 41.5), Volumes 1.58 GB (Recovery), 3.70M files. A scan of `/System/Volumes/Preboot` alone: 11.27 GB.

**Before Plan 2**
- The app raises the soft `RLIMIT_NOFILE` at launch like `maclean-scan` does (min(hard, 10240)); otherwise one scan gets ~15 reads in flight.
- Add a `ScanBoundary.forRoot(_:mounts:)` seam so snapshot, stacked-mount, external-disk and Preboot-root cases get deterministic tests.
- Decide the I/O queue's QoS (fixed `.utility` vs the submitter's).
- Add a bulk `fileCounts()` (O(n) bottom-up); `fileCount(of:)` is O(subtree) and must not be called per row.
- Check `Task.isCancelled` after `finish()` (it ignores cancellation, ~1 s on `/`).
- A hung syscall blocks the cancel drain; the spec's 60 s "not responding" rule needs continuations that resume early.

**Before Plan 4**
- Archive: mode 0600 / owned by the user it's for, fsync before rename, consider a checksum.

**Later / minor**
- `budgetIsReleasedAfterCancel` can't detect a leaked grant: acquire twice after the cancel and expect both full.
- No test for a partly unreadable descendable volume; `concurrentScansShareSmallBudget` doesn't prove the scans overlapped; no `/dev/fd` leak check; root handle not charged in the fd grant.
- `fileCountIsComputed` lacks hard-link/clone-extra nodes; no streamed-write error-path test; doc note on `ChunkedColumn`'s shared setter.
- Scans are ~2–3% slower with ~25% more kernel CPU since reads moved to the dispatch queue; if a sudo `/` scan exceeds 30 s, try `desiredInFlight = activeProcessorCount`.
