# Maclean Plan 3a: Collector and Delete Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A DaisyDisk-style collector and permanent delete:
- Collect items from the chart, the list or Finder.
- Collected items vanish, and their ancestors shrink.
- Delete runs after a 5-second countdown, with safety re-checks.
- Items that need it are deleted with administrator rights.
- A summary at the end lists what changed since the scan and what failed.

**Architecture:**
- **TreeView** (MacleanKit): an overlay on the immutable `FileTree` holding collected and removed nodes, with effective sizes. The chart, the list and keyboard traversal read through it.
- **Session ownership:** each `ScanSession` owns one `TreeView` and one `DeleteController`, so every window showing that session agrees.
- **MacleanCore** gains `ProtectionRules`, the `Deleter`, and an admin-batch protocol.
- **Admin deletes:** the bundled `maclean-scan --delete` runs the same `Deleter` as root, behind the standard password prompt.

**Tech Stack:**
- Swift 6.4 (language mode 6), SwiftPM with Command Line Tools only.
- SwiftUI + AppKit, Swift Testing.
- POSIX `openat`/`unlinkat`/`fstatat`.
- `osascript` for the admin prompt.

**Spec:** `docs/superpowers/specs/2026-11-07-maclean-collector-cleanup-design.md`, Part 1 (§4) and §6.4 "Collector context". This spec is binding. Product spec: `docs/superpowers/specs/2026-11-07-maclean-design.md` §5.7, §5.8, §6.6. Plan 2 follow-ups: `docs/superpowers/plans/2026-11-07-maclean-02-app-shell.md` "Before Plan 3".

## Global Constraints

- **Toolchain:** macOS 14+, Swift 6 language mode, no third-party dependencies.
  - Tests run with `swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`.
  - `@State` doesn't compile with Command Line Tools. Use `State(initialValue:)` in `init`. `@Observable` works.
- **Never delete real user files.** Delete tests use `TempDir` fixtures only. Manual checks use a scratch folder created for the check, such as `~/maclean-scratch`, never real data.
- **Delete is permanent by default.** Settings › General has "Move to Trash instead of deleting permanently" (`UserDefaults` key `MoveToTrashInsteadOfDeleting`, default `false`).
- **Countdown:** 5 seconds, with Cancel. Copy: "Deleting <n> items, <size> in <s>…". Red is used only for Delete.
- **Collector protection** follows design §6.4 "Collector context". Refused:
  - SIP paths: `/System`, `/bin`, `/sbin`, `/usr` except `/usr/local` and below, `/Library/Apple`.
  - Volume roots, meaning `/` and every mount point.
  - `/Library` itself and the home folder itself.
  - Maclean's own bundle.
  - Anything on a Time Machine volume.
  - Unsafe path shapes.
  - "Smaller objects" segments.
  - The never-clean list does **not** apply.
- **The collector and overlay belong to the `ScanSession`.** Every window showing that session shares them.
- **Drags never carry file URLs out of Maclean.** The internal pasteboard type is `org.maclean.node`, so a drag can't move or copy real files in Finder.
- **Look:** Plan 2's light & airy style. Both appearances. Body text ≥ 13 pt with `.monospacedDigit()` sizes. Middle truncation with a tooltip. Keyboard reachable.
- **Collect and uncollect** animate with an angle morph of about 0.25 s ease-in-out. Reduce Motion turns it into a crossfade.
- **Commits:** Conventional Commits, with no AI attribution trailer. Never push.

## Review Focus

1. **Collect a folder, then uncollect it** (alone, or after absorbing already-collected children). Every ancestor's size returns exactly to the scanned value, and the chart is identical to before. Test in Task 2.
2. **An item renamed, deleted or replaced outside Maclean between scan and Delete.**
   - Gone: shown as "Already gone" and removed from the map.
   - Replaced (different inode): refused with "Replaced since the scan. Rescan to delete it." It is never deleted.
   - Test in Task 4.
3. **A symlink swapped in for a folder (or inside it) during deletion.** Only the link is removed, and nothing outside the item is touched. Test in Task 4.
4. **Delete stopped mid-way, or the password prompt cancelled.** Only items actually deleted leave the collector; everything else stays collected with its reason. Test in Task 7.
5. **Rescan while items are collected,** and collecting while a delete runs.
   - On rescan, surviving paths stay collected, with the new sizes. A note counts the dropped ones.
   - During a delete, collect and uncollect are disabled.
   - Test in Task 5.

---

### Task 1: Plan 2 prerequisites (structure only, no behaviour change)

**Files:**
- Create:
  - `Sources/MacleanCore/PathUtil.swift`
  - `Sources/Maclean/Chart/SunburstRepresentable.swift`
  - `Sources/Maclean/Chart/SunburstChartView.swift` (core view state, setContent, layout)
  - `Sources/Maclean/Chart/SunburstChartView+Input.swift` (mouse, keys, gestures, menu)
  - `Sources/Maclean/Chart/SunburstChartView+Rendering.swift` (cache, colours, drawSegments)
  - `Sources/Maclean/Chart/SunburstChartView+Transition.swift`
  - `Sources/Maclean/Chart/SunburstChartView+Accessibility.swift`
  - `Tests/MacleanAppTests/ResultViewModelTests.swift`
- Delete: `Sources/Maclean/SunburstView.swift`. Its `SunburstView` SwiftUI wrapper moves to `Chart/SunburstRepresentable.swift`.
- Modify:
  - `Package.swift`: add test target `MacleanAppTests`, which depends on `Maclean`.
  - `Sources/MacleanCore/FileTree.swift`
  - `Sources/MacleanKit/SunburstLayout.swift`
  - `Sources/Maclean/ResultViewModel.swift`
  - `Sources/Maclean/ScanSession.swift`
- Test: `Tests/MacleanCoreTests/FileTreeTests.swift`, `Tests/MacleanAppTests/ResultViewModelTests.swift`

**Interfaces:**
- Produces:
```swift
extension FileTree { public func node(atPath path: String) -> NodeID? }  // replaces ResultViewModel.resolve and ScanSession.exists
public enum PathUtil { public static func isInside(_ path: String, orEqualTo root: String) -> Bool }  // component-wise; "/" contains everything
extension SegmentKind { public init(flags: NodeFlags) }  // the mapping now inlined in SunburstLayout.init
```
- Decisions:
  - **History fix:** when `history`'s `didSet` can't resolve the new current path, it falls back to the nearest surviving ancestor. It updates `currentPath` and `currentNode` to it, and replaces the history entry. Today those two keep stale values.
  - **Size invariant:** a directory's size equals the sum of its children's sizes. Document this on `FileTree.size(of:)`, and pin it with a test. `SunburstLayout`'s tail math relies on it.
  - **Fallback:** if `@testable import Maclean` won't link with Command Line Tools, drop the `MacleanAppTests` target, record that in the ledger, and keep the app-level tests as manual checks. Don't restructure the app to make it testable.

- [ ] **Step 1: Write failing tests**
```swift
// FileTreeTests
@Test func nodeAtPathFindsNestedAndRoot()   // fixture a/b/c.txt: node(atPath: root+"/a/b/c.txt") names "c.txt"; node(atPath: rootPath) == root; "/elsewhere" → nil; root+"/a/zz" → nil
@Test func directorySizeIsSumOfChildren()    // scanned fixture with nested dirs: for every dir d, size(d) == children(d).map(size).sum
// ResultViewModelTests (session built from a TempDir scan)
@Test func vanishedCurrentFolderFallsBackToAncestor()  // visit a/b, rescan after deleting b in the TempDir → currentNode == node(a), history.current == path(a)
@Test func backSkipsMissingEntries()
```
- [ ] **Step 2: Run them and confirm they fail.** `node(atPath:)` is undefined, and the fallback test fails.
- [ ] **Step 3: Implement.**
  - Add `node(atPath:)`, `PathUtil.isInside`, and `SegmentKind(flags:)`, and switch the existing callers to them.
  - Fix the `didSet` fallback.
  - Split `SunburstView.swift` into the five `Chart/` files by moving code, with no edits beyond access levels (`private` → `fileprivate`/internal where the split needs it).
- [ ] **Step 4: Run all tests and confirm they pass.** Then run `scripts/build-app.sh`, open the app, scan `~/Downloads`, and drill in and out. The behaviour should be unchanged.
- [ ] **Step 5: Commit.**

---

### Task 2: TreeView overlay, with layout and list reading through it

**Files:**
- Create: `Sources/MacleanKit/TreeView.swift`, `Tests/MacleanKitTests/TreeViewTests.swift`
- Modify:
  - `Sources/MacleanKit/SunburstLayout.swift`: `init(view: TreeView, root:rings:minAngle:)` replaces `init(tree:…)`.
  - `Tests/MacleanKitTests/SunburstLayoutTests.swift`: wrap fixtures in `TreeView(tree:)`.

**Interfaces:**
- Produces:
```swift
public struct TreeView: Sendable {
  public let tree: FileTree
  public private(set) var generation: Int            // +1 per mutation
  public private(set) var collected: [NodeID]        // collect order; never holds a descendant of another collected node
  public private(set) var removed: Set<NodeID>
  public init(tree: FileTree)
  public func size(of id: NodeID) -> Int64           // effective: raw − sizes of hidden nodes beneath it (raw for a hidden node itself)
  public func isHidden(_ id: NodeID) -> Bool         // id or an ancestor is collected or removed
  public func children(of id: NodeID) -> ViewChildren  // visible only, sorted by effective size desc, ties keep tree order
  public var collectedSize: Int64                    // sum of raw sizes of `collected`
  @discardableResult public mutating func collect(_ ids: [NodeID]) -> [NodeID]  // returns those actually added; skips root, hidden ids; absorbs collected descendants
  public mutating func uncollect(_ ids: [NodeID])
  public mutating func uncollectAll()
  public mutating func markRemoved(_ ids: [NodeID])   // ids must be in `collected`; moves them to `removed`; sizes stay subtracted
}
public enum ViewChildren: RandomAccessCollection, Sendable { case raw(NodeChildren), reordered([NodeID]) } // Element == NodeID, Int indices
```
- Decisions:
  - **Effective sizes:** stored as a `[Int32: Int64]` delta per affected ancestor.
  - **Reordered children:** cached per parent whose children changed size or visibility. Every other parent returns `.raw` with no allocation.
  - **Batch updates:** `collect` and `uncollect` of a batch recompute each affected parent's list once.
  - `SunburstLayout` uses `view.size` and `view.children` everywhere. The binary-search cutoff stays valid because `children` is sorted by effective size.

- [ ] **Step 1: Write failing tests**
```swift
@Test func collectShrinksEveryAncestor()      // collect f (size 100) at a/b/f: size(b), size(a), size(root) each drop by 100; isHidden(f); children(b) lacks f
@Test func uncollectRestoresExactly()        // collect then uncollect: every node's size == tree.size; children(of:) for each dir equals tree order
@Test func collectingParentAbsorbsChildren() // collect a/b/f then a/b: collected == [b]; size(root) == raw − size(b) (not − size(b) − size(f)); uncollect b → f is NOT collected
@Test func collectSkipsRootAndHidden()       // collect([root]) == []; after collect b, collect([f]) == []
@Test func childrenResortByEffectiveSize()   // root kids x(300) > y(200); collect 150 inside x → children(root) == [y, x]
@Test func removedStaysSubtracted()          // collect f, markRemoved([f]): collected empty, removed {f}, size(b) still raw − 100; uncollectAll doesn't restore f
@Test func layoutTailMatchesEffectiveSizes() // SunburstLayout(view:) after collecting: sum of ring-1 segment spans == 2π (±1e-9), no segment for f
@Test func batchCollectIsFast()              // folder of 10_000 files: collect(all children) < 100 ms; size(folder) == 0
```
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement `TreeView` and `ViewChildren`, then switch `SunburstLayout` to `init(view:…)`.**
- [ ] **Step 4: Run all tests and confirm they pass.** The existing layout tests should pass when wrapped in `TreeView(tree:)`.
- [ ] **Step 5: Commit.**

---

### Task 3: ProtectionRules (collector context)

**Files:**
- Create:
  - `Sources/MacleanCore/ProtectionRules.swift`
  - `Tests/MacleanCoreTests/ProtectionRulesTests.swift`
  - `Tests/MacleanCoreTests/Resources/dangerous_paths.txt`: Maclean's own corpus of at least 100 paths, covering the categories in design §6.4. Mole is GPL-3.0, so nothing is copied from it.
- Modify: `Package.swift`, so `MacleanCoreTests` gets `resources: [.copy("Resources")]`.

**Interfaces:**
- Produces:
```swift
public enum ProtectionContext: Sendable { case collector }   // Plan 3b adds .smartClean
public enum Refusal: String, Sendable, Codable, Equatable {
  case systemProtected, volumeRoot, libraryItself, homeItself, macleanItself, timeMachine, unsafePath
  public func message(name: String) -> String
}
public struct ProtectionEnvironment: Sendable, Codable, Equatable {
  public var home: String; public var appBundle: String; public var mountPoints: [String]; public var timeMachineMounts: [String]
  public init(home: String, appBundle: String, mountPoints: [String], timeMachineMounts: [String])
  public static func current() -> ProtectionEnvironment  // NSHomeDirectory(), Bundle.main.bundlePath, ScanBoundary.mounts()
}
public enum ProtectionRules {
  public static func refusal(for path: String, context: ProtectionContext = .collector, in env: ProtectionEnvironment) -> Refusal?
}
```
- Exact copy for `message(name:)`:
  - `systemProtected`: "“\(name)” is protected by macOS and can't be deleted."
  - `volumeRoot`: "“\(name)” is a whole disk. Collect the folders inside it instead."
  - `libraryItself`: "“Library” is needed by macOS. Collect the folders inside it instead."
  - `homeItself`: "Your home folder can't be collected. Collect the folders inside it instead."
  - `macleanItself`: "Maclean can't delete itself."
  - `timeMachine`: "Items on Time Machine backups can't be deleted."
  - `unsafePath`: "This item's path can't be deleted safely."
- Decisions:
  - **Comparisons** are component-wise and case-insensitive, because APFS is case-insensitive by default.
  - **Unsafe path:** not absolute, or contains a `.`/`..` component, an empty component (`//`), or control characters (C0, DEL, C1).
  - **Time Machine mounts:** mount points under `/Volumes/.timemachine/`, or whose root contains `Backups.backupdb`. *ponytail:* this misses APFS backup volumes mounted elsewhere; use the APFS role "Backup" through `getattrlist` if that comes up.
  - **Path forms:** `/private/var/...` and `/var/...` are the same; normalise `/var`, `/etc` and `/tmp` to their `/private` form before checking.

- [ ] **Step 1: Write failing tests**
```swift
let env = ProtectionEnvironment(home: "/Users/me", appBundle: "/Applications/Maclean.app",
                                mountPoints: ["/", "/System/Volumes/Data", "/Volumes/Ext"], timeMachineMounts: ["/Volumes/TM"])
@Test func refusesCollectorProtectedPaths()   // /System, /System/Library/X, /usr/bin/ls, /bin, /sbin/x, /Library/Apple/x → .systemProtected; "/", "/Volumes/Ext" → .volumeRoot; /Library → .libraryItself; /Users/me → .homeItself; /Applications/Maclean.app and /Applications/Maclean.app/Contents → .macleanItself; /Volumes/TM/x → .timeMachine
@Test func caseVariantsAreRefused()           // "/SYSTEM/Library", "/users/ME" → refused
@Test func allowsContentsDaisyDiskAllows()    // /usr/local/lib, /Library/Caches, /Users/me/Library, /Users/me/Pictures/Photos Library.photoslibrary, /Users/me/Library/Keychains, /Volumes/Ext/x, /private/var/folders/x → nil
@Test func unsafeShapesRefused()              // "relative", "/a/../System", "/a/./b", "/a//b", "/a/\u{1B}b" → .unsafePath
@Test func dangerousCorpusSystemSubsetRefused() // every corpus line that is a system root, traversal or control-char path is refused; the lines below are explicitly collectable in collector context and listed in the test: <the corpus's Keychains/user-data entries>
```
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them and confirm they pass.**
- [ ] **Step 5: Commit.**

---

### Task 4: Deleter (identity, re-walk, fd-relative removal, Trash)

**Files:**
- Create: `Sources/MacleanCore/Deleter.swift`, `Tests/MacleanCoreTests/DeleterTests.swift`

**Interfaces:**
- Consumes: `ProtectionRules.refusal`, `Scanner.scan(path:)`, `FileTree.fileCount(of:)`.
- Produces:
```swift
public struct DeleteRequest: Sendable, Hashable, Codable {
  public let path: String; public let inode: UInt64; public let device: Int32
  public let size: Int64; public let fileCount: Int64; public let isDirectory: Bool
  public init(path:inode:device:size:fileCount:isDirectory:)
}
public enum DeleteMode: String, Sendable, Codable { case permanent, trash }
public enum DeleteOutcome: Sendable, Equatable, Codable {
  case deleted(freed: Int64)              // trash mode: freed == size moved
  case changedSinceScan(size: Int64, fileCount: Int64)
  case replaced                            // inode/device differ
  case missing                             // ENOENT at check time
  case refused(Refusal)
  case needsAdmin(started: Bool)           // EACCES/EPERM; started = something was already removed
  case failed(String)                      // strerror text
}
public struct Deleter: Sendable {
  public init(mode: DeleteMode, environment: ProtectionEnvironment)
  public func delete(_ request: DeleteRequest, force: Bool = false) async -> DeleteOutcome
}
```
- Decisions, in order:
  1. Protection check.
  2. Open the parent with `open(parent, O_RDONLY|O_DIRECTORY)`. Ancestors may be symlinks in collector context.
  3. `fstatat(pfd, name, AT_SYMLINK_NOFOLLOW)`. `ENOENT` gives `.missing`. An inode or device mismatch gives `.replaced`.
  4. Unless `force`: re-walk the item and compare. For a directory, `Scanner.scan(path:)` gives the root size and `fileCount`; for a file, `st_blocks * 512`. Changed means a file-count difference > 0, or a size difference > `max(size / 100, 1_048_576)`; return `.changedSinceScan` with the current values. A re-walk tree with any `.restricted` node gives `.needsAdmin(started: false)`.
  5. **Permanent:** a non-directory gets `unlinkat(pfd, name, 0)`. A directory gets the recursive algorithm below.
  6. **Trash:** `FileManager.trashItem` after the identity check.
  7. `EACCES`/`EPERM` gives `.needsAdmin(started:)`. Any other errno gives `.failed(strerror)`. Freed is the measured current size, or `request.size` when `force` skipped the re-walk.
- The directory removal algorithm (the reason this task exists):
```
removeTree(pfd, name, expectIno):
  fd = openat(pfd, name, O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)   // ELOOP/ENOTDIR → it became a symlink/file: unlinkat(pfd, name, 0) and stop
  fstat(fd) inode must == expectIno (else fail .replaced, touch nothing)
  for entry in readdir(fdopendir(dup(fd))) except . and ..:
      fstatat(fd, entry, AT_SYMLINK_NOFOLLOW)
      if S_ISDIR: removeTree(fd, entry, st_ino) else unlinkat(fd, entry, 0)
  close(fd); unlinkat(pfd, name, AT_REMOVEDIR)
```

- [ ] **Step 1: Write failing tests** (all in `TempDir`)
```swift
@Test func deletesFileAndFolderPermanently()   // request from a fresh scan → .deleted(freed: scanned size); path gone
@Test func missingReportsMissing()             // remove the file first → .missing
@Test func replacedIsNeverDeleted()            // delete + recreate same name (new inode) → .replaced; new file still exists
@Test func changedFolderIsReported()           // add 3 files after building the request → .changedSinceScan(fileCount: old+3); folder untouched; force: true → .deleted
@Test func smallCacheChurnIsNotChange()        // rewrite one 10 KB file in a 50 MB folder → .deleted
@Test func symlinkIsDeletedAsLinkOnly()        // item is a symlink to a TempDir folder "keep" → link gone, keep/ intact
@Test func symlinkSwappedInsideTreeIsNotFollowed() // folder item contains sub/ which is replaced by a symlink to "keep" after the request (force: true) → item gone, keep/ intact
@Test func refusedPathsAreRefused()            // env.home == TempDir path; request for TempDir itself → .refused(.homeItself)
@Test func permissionDeniedNeedsAdmin()        // chmod 0500 on parent → .needsAdmin(started: false); file still there
@Test func trashModeMovesToTrash()             // mode .trash on a TempDir file → .deleted, file gone from its path. Test name note: runs only when FileManager.trashItem succeeds in the test environment; otherwise skip with a recorded reason
```
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement `Deleter`.**
- [ ] **Step 4: Run them and confirm they pass, then run the full suite.**
- [ ] **Step 5: Commit.**

---

### Task 5: Session-owned collector, rescan carry-over and the morph

**Files:**
- Modify:
  - `Sources/Maclean/ScanSession.swift`
  - `Sources/Maclean/ResultViewModel.swift` (all `tree.size`/`tree.children` reads of visible structure go through `session.view`)
  - `Sources/Maclean/SideListView.swift`
  - `Sources/Maclean/BreadcrumbBar.swift`
  - `Sources/Maclean/ResultView.swift`
  - `Sources/Maclean/Chart/*`
  - `Sources/Maclean/SessionRegistry.swift`
  - `Sources/Maclean/VolumeRowView.swift` (Forget confirmation)
- Test: `Tests/MacleanAppTests/CollectorSessionTests.swift`

**Interfaces:**
- Consumes: `TreeView`, `ProtectionRules`, `FileTree.node(atPath:)`.
- Produces:
```swift
extension ScanSession {
  private(set) var view: TreeView?                 // set with state .finished; nil otherwise
  var isDeleting: Bool                             // internal setter; Task 7's DeleteController sets it during countdown and run
  /// Refusal first: the first refused id stops nothing else; returns refusals by node for the UI message.
  @discardableResult func collect(_ ids: [NodeID]) -> [(NodeID, Refusal)]   // no-op while isDeleting
  func uncollect(_ ids: [NodeID]); func uncollectAll()
  func markRemoved(_ ids: [NodeID])
  private(set) var carryOverDropped: Int?          // set after a rescan dropped collected paths; cleared on read by the view
  var protection: ProtectionEnvironment            // ProtectionEnvironment.current(), injectable for tests
}
extension ResultViewModel {
  func viewDidChange()      // called on session.view.generation change: relayout same root; if currentNode is hidden, visit nearest visible ancestor
  func toggleCollected(_ id: NodeID)   // ⌘⌫: collect if visible, else uncollect if it's in collected; refusal → notice via collectorRefusal
  private(set) var collectorRefusal: Notice?
}
```
- Decisions:
  - **Rescan carry-over:** in `ScanSession.finish`, build the new `TreeView`, collect `node(atPath:)` for each previously collected path, set `carryOverDropped` to the count that didn't resolve (nil when 0), and drop `removed`.
  - **Forget Scan Result:** with a non-empty collector, it asks first: "Forget this scan? <n> collected items will be removed from the collector." [Forget] [Cancel].
  - **Chart:** a new `Transition.Kind.morph`, used when the layout root is unchanged and only the view generation moved.
    - Segments are matched by `NodeID`.
    - New segments grow from zero width at their start angle; vanished ones shrink to zero width.
    - The smaller-objects segment is matched by `parent`.
    - Duration 0.25 s, ease-in-out. Reduce Motion gives `.crossfade`.
  - **⌘⌫ target:** acts on `actionTarget` only (the hovered or selected item), never falling back to the current folder.
  - **Smaller objects:** a smaller-objects segment as target produces the refusal "“smaller objects” is a group. Expand it and collect the items inside."
- Check that `ResultViewModel.visibleChildCount`, `moveSelection` and `traverse` use `view.children`, so hidden items can't be selected.

- [ ] **Step 1: Write failing tests**
```swift
@Test func collectHidesInAllModelsOfSession()   // two ResultViewModels on one session; collect via session → both models' listTarget children lack it after viewDidChange()
@Test func refusedCollectReturnsReason()        // session.protection.home = path of the scanned child folder "h"; collect([node h]) → [(h, .homeItself)], view.collected empty
@Test func rescanCarriesOverByPath()            // collect a and b; delete b on disk; rescan → view.collected paths == [a], carryOverDropped == 1, a's size is the new scan's
@Test func collectIsNoOpWhileDeleting()         // isDeleting forced true via test hook → collect returns [], collected unchanged
@Test func currentFolderHiddenNavigatesUp()     // model at a/b; other model collects a → first model's currentNode == root
@Test func cmdDeleteOnSmallerObjectsRefuses()
```
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the tests, and confirm the morph manually.** Build the app, scan `~/maclean-scratch` (create it with nested dummy files first), and press ⌘⌫ over a segment. The segment collapses, its neighbours widen, and nothing jumps.
- [ ] **Step 5: Commit.**

---

### Task 6: Collector UI (bar, panel, drag and drop, menus)

**Files:**
- Modify: `Sources/Maclean/CollectorBar.swift`, `Sources/Maclean/AppCommands.swift`, `Sources/Maclean/ResultView.swift`, `Sources/Maclean/SideListView.swift`, `Sources/Maclean/Chart/SunburstChartView+Input.swift`
- Create:
  - `Sources/Maclean/CollectorPanel.swift`
  - `Sources/Maclean/NodeDrag.swift`: pasteboard type `org.maclean.node`, payload `{sessionID: UUID, path: String}` as JSON.

**Interfaces:**
- Consumes: the Task 5 session API; `Actions`/`ResultActions` for Preview, Show in Finder and Open in Terminal.
- Produces:
```swift
extension UTType { static let macleanNode: UTType }   // exported identifier "org.maclean.node"; add to Info.plist UTExportedTypeDeclarations
struct NodeDragPayload: Codable { let sessionID: UUID; let path: String }
```
- Decisions:
  - **The bar:**
    - Empty: as now.
    - Non-empty: the circle shows a ring proportional to `collectedSize` / the root's raw size and the total inside, then "<size> collected", a spacer, and a red **Delete** button.
    - The bar is an `onDrop` target for `.macleanNode` (from this session, collect) and `.fileURL` (Finder: resolve with `node(atPath:)` on the canonical path). A Finder path outside the scan, or already hidden, is refused with "“<name>” isn't in this scan."
  - **Refusal messages** show in a popover anchored to the circle, dismissed after 4 s or on click, and posted as a VoiceOver announcement.
  - **The panel:** clicking the circle, or pressing Return or Space on it, toggles a panel that slides up over the chart, up to 40% of the window height.
    - Rows show icon, name (middle-truncated), the parent path tail (secondary) and size, plus an × button.
    - Row context menu: Preview, Show in Finder, Open in Terminal, Remove “<name>” from Collector (⌘⌫).
    - Rows are drag sources (`.macleanNode`). The chart accepts a `.macleanNode` drop of a collected item and uncollects it.
    - Esc closes the panel.
  - **Drag sources:**
    - The chart starts a drag after 4 pt of movement on a segment that isn't smaller objects.
    - List rows use `.onDrag`.
    - Neither ever puts a file URL on the pasteboard.
  - **Menus:**
    - The chart and list context menus gain Move “<name>” to Collector.
    - The Action menu gains:
      - Move to Collector (⌘⌫, toggles on `actionTarget`)
      - Move All Items from Current Folder to Collector
      - Remove All Items from Collector
      - Delete Collected Items (Task 7 wires it)
  - **Accessibility:**
    - Bar label: "Collector, <n> items, <size>".
    - Each panel row: "<name>, <size>", with a "Remove from Collector" action.

- [ ] **Step 1: Build, run, and check by hand** in a scratch folder: drag a segment to the bar, drag a list row, drag a Finder file from the scanned folder and one from outside, ⌘⌫ toggle, open the panel, ×, drag a panel row back to the chart, Move All from Current Folder, Remove All, and a refusal (scan `/` and collect `System`). Check both appearances. View code is covered by the Task 5 model tests plus this check. Record the results in the ledger.
- [ ] **Step 2: Commit.**

---

### Task 7: Delete flow (countdown, run, admin batch, summary, Settings)

**Files:**
- Create:
  - `Sources/MacleanCore/AdminDelete.swift`
  - `Sources/Maclean/DeleteController.swift`
  - `Sources/Maclean/AdminRunner.swift`
  - `Sources/Maclean/DeleteSummaryView.swift`
  - `Sources/Maclean/DeleteMenuItem.swift`
  - `Tests/MacleanCoreTests/AdminDeleteTests.swift`
  - `Tests/MacleanAppTests/DeleteControllerTests.swift`
- Modify:
  - `Sources/maclean-scan/main.swift` (`--delete` mode)
  - `scripts/build-app.sh` (copy `maclean-scan` to `Contents/MacOS/maclean-scan` before signing)
  - `Sources/Maclean/CollectorBar.swift`
  - `Sources/Maclean/SettingsView.swift`
  - `Sources/Maclean/MacleanApp.swift`
  - `Sources/Maclean/ResultViewModel.swift` (`refreshVolumeSpace()`, made internal from `loadVolumeSpace`)
  - `Sources/Maclean/StartView.swift` (refresh on `.macleanDidDelete`)
  - `docs/manual-checklist.md`

**Interfaces:**
- Consumes: `Deleter`, `DeleteRequest`, `DeleteOutcome`, `ProtectionEnvironment`, the Task 5 session API.
- Produces:
```swift
public enum AdminDelete {
  public struct Item: Codable, Sendable, Equatable { public let request: DeleteRequest; public let force: Bool }
  public static func arguments(items: [Item], environment: ProtectionEnvironment) -> [String]   // ["--delete", "--env", <JSON of env>, "--items", <JSON of items>]
  public static func parse(_ arguments: [String]) throws -> (items: [Item], environment: ProtectionEnvironment)
  public static func encode(path: String, outcome: DeleteOutcome) -> String       // one JSON line
  public static func decode(_ output: String) -> [String: DeleteOutcome]          // path → outcome; malformed lines ignored
}
@MainActor @Observable final class DeleteController {
  enum Phase: Equatable { case idle, countdown(remaining: Int), running(done: Int, total: Int), summary(DeleteReport) }
  private(set) var phase: Phase
  init(session: ScanSession, deleter: @escaping (DeleteMode) -> any DeleterProtocol = { Deleter(mode: $0, environment: .current()) },
       admin: any AdminRunning = AdminRunner(), clock: any Clock<Duration> = ContinuousClock())
  func start()            // snapshot of session.view.collected → requests; countdown 5…1
  func cancel()           // countdown → idle (nothing deleted); running → stop after the current item
  func resolveChanged(_ paths: [String], deleteAnyway: Bool)   // summary action: re-run with force: true, or keep collected
  func dismissSummary()
}
struct DeleteReport: Equatable { struct Changed: Equatable { var size: Int64; var files: Int64 }
  var freed: Int64; var deleted: [String]; var alreadyGone: [String]; var changed: [String: Changed]; var failed: [String: String] }
protocol DeleterProtocol: Sendable { func delete(_ r: DeleteRequest, force: Bool) async -> DeleteOutcome }   // `extension Deleter: DeleterProtocol {}` in the app
extension ScanSession { var deletion: DeleteController { get } }   // created lazily, one per session; it sets session.isDeleting
protocol AdminRunning: Sendable { func run(_ arguments: [String]) async throws -> String }   // throws AdminRunnerError.cancelled on user cancel
extension Notification.Name { static let macleanDidDelete: Notification.Name }
```
- Decisions:
  - **The run:**
    - Items run sequentially off the main actor. `cancel()` during the run is checked between items.
    - `.deleted` and `.missing` → `session.markRemoved`.
    - `.changedSinceScan`, `.replaced`, `.refused` and `.failed` stay collected.
    - `.needsAdmin` is queued.
  - **The admin batch:**
    - After the pass, if the queue isn't empty and the mode is permanent, one `AdminRunner.run(AdminDelete.arguments(...))` runs, with `force: started` per item.
    - In Trash mode the queue isn't sent. Each item fails with "Needs administrator rights, so it can't be moved to the Trash. Turn off “Move to Trash” in Settings to delete it."
    - User cancel → each queued item fails with "Administrator password not given."
  - **`AdminRunner`** runs `/usr/bin/osascript` with argv. Nothing is interpolated into the script text:
    ```
    on run argv
      set cmd to quoted form of (item 1 of argv)
      repeat with a in rest of argv
        set cmd to cmd & " " & quoted form of a
      end repeat
      do shell script cmd with administrator privileges
    end run
    ```
    - argv[0] is `Bundle.main.bundleURL/Contents/MacOS/maclean-scan`.
    - Exit status 1 with `-128` in stderr → `.cancelled`.
    - The call runs off the main thread with a 10-minute timeout.
  - **`maclean-scan --delete`:**
    - Parses with `AdminDelete.parse`.
    - Refuses unless `getuid() == 0`.
    - Rebuilds `mountPoints`/`timeMachineMounts` itself rather than trusting the app, keeping `home`/`appBundle` from the argument.
    - Runs `Deleter(mode: .permanent)` per item, prints one `encode` line each, and exits 0.
  - **Bar states while deleting:**
    - Countdown: "Deleting <n> items, <size> in <s>…" plus Cancel.
    - Running: "Deleting <done> of <total>…" plus a progress bar and Stop.
  - **The summary sheet** on the window:
    - Title "Freed <size>", or "Moved <size> to the Trash".
    - Sections, each shown only when non-empty:
      - "Changed since the scan", with per-row and "all" Delete Anyway / Keep.
      - "Couldn't delete", with reasons.
      - "Already gone".
    - A Done button.
  - **After a run with any deletions:** post `.macleanDidDelete`. Open models call `refreshVolumeSpace()`, and the start screen refreshes its volumes.
  - **`DeleteMenuItem`:** an AppKit `NSMenuItem` "Delete Collected Items" inserted at the end of the Action menu after launch. Its target conforms to `NSMenuItemValidation` and enables it only when the front model's session has collected items and `!isDeleting`. Activating it calls `start()`. This is the Plan 2 follow-up.
  - **Settings › General** gains the Toggle "Move to Trash instead of deleting permanently", with the footnote "Off: deleted items are gone for good, as in DaisyDisk."

- [ ] **Step 1: Write failing tests**
```swift
// AdminDeleteTests
@Test func argumentsRoundTrip()          // parse(arguments(items, env)) == (items, env), including paths with spaces, quotes, newlines and "--delete"
@Test func outcomeLinesRoundTrip()       // encode/decode every DeleteOutcome case; garbage line ignored
// DeleteControllerTests (fake DeleterProtocol, fake AdminRunning, test clock)
@Test func cancelDuringCountdownDeletesNothing()
@Test func stopMidRunKeepsRemainingCollected()  // 5 items, cancel after 2nd → removed == 2 items, collected == 3
@Test func adminCancelKeepsItemsWithReason()    // fake admin throws .cancelled → those items collected, report.failed has "Administrator password not given."
@Test func adminSendsForceForStartedItems()     // needsAdmin(started: true) → admin receives Item(force: true)
@Test func trashModeDoesNotEscalate()
@Test func changedThenDeleteAnywayForces()      // .changedSinceScan → resolveChanged(deleteAnyway: true) calls deleter with force: true → removed
@Test func missingCountsAsRemoved()
```
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement everything above.**
- [ ] **Step 4: Run all tests, then do the manual check.** Add these to `docs/manual-checklist.md` under "Collector and delete":
  1. Create `~/maclean-scratch` with folders and files, scan it, collect 3 items, press Delete, and let it finish. Check the summary and that Finder confirms they're gone.
  2. Press Delete, then Cancel within 5 s. Nothing is deleted.
  3. Collect a folder, add a file to it in Finder, then Delete. It appears under "Changed since the scan"; check both Keep and Delete Anyway.
  4. `sudo mkdir ~/maclean-scratch/rootdir` with a file inside it (the owner runs this). Collect it and Delete: the password prompt appears. Approve once, and cancel once.
  5. Turn on Trash mode, delete a file, and find it in the Trash.
  6. Delete Collected Items in the Action menu is disabled with an empty collector and during a run.
  7. Scan `/`, collect `/Library/Caches/<some folder>`, start Delete, and **Cancel during the countdown**. Only the prompt path is exercised; nothing outside the scratch folder is ever deleted.
- [ ] **Step 5: Commit.**

---

### Task 8: Docs and outcome

**Files:** `README.md` (Collector and Delete section, plus the Trash setting), `docs/superpowers/plans/2026-11-07-maclean-03a-collector-delete.md` (append "Outcome and follow-ups")

- [ ] **Step 1:** Run the full test suite and `scripts/build-app.sh`, and record the pass counts.
- [ ] **Step 2:** Update the README. Append the outcome, plus the follow-ups for Plan 3b (Smart Clean reuses `Deleter`, `AdminDelete`, `ProtectionRules`, and adds `.smartClean`).
- [ ] **Step 3: Commit.**

---

## Outcome and follow-ups (recorded after execution)

Built on branch `plan-03a-collector-delete`, 13 commits from main before the final-review fix wave (see "Final-review fix wave" below for the count after it); 193 tests (43 MacleanKit + 109 MacleanCore + 41 MacleanApp), all passing, and `scripts/build-app.sh` builds and signs the bundle. Shipped: `TreeView` overlay and angle-morph relayout, `node(atPath:)` and the chart-file split, collector protection rules with an own dangerous-path corpus (146 paths), the fd-based `Deleter` (permanent or Trash), `AdminDelete` with the bundled `maclean-scan --delete` run as root behind an osascript password prompt, the collector bar, panel and drag and drop (chart, list, Finder), ⌘⌫, context and Action menu items, the `DeleteController` (5-second countdown, Cancel, summary with "changed since the scan" and Delete Anyway), and the Settings Trash toggle.

**Rulings worth remembering**
- **Licence correction:** mole is GPL-3.0, not MIT as the spec said. Nothing was copied; Maclean's own corpus covers the same categories. The spec and plan were corrected.
- **Collector protection:** ancestors of the home folder and of Maclean's bundle are refused (collecting them would delete the protected item); `/usr/local` itself is collectable; other users' home folders stay collectable (OS permissions and the admin prompt guard them).
- **Deleter strictness:** an item that turned into a symlink or file before removal is `.replaced` and nothing is unlinked; identity is re-checked after the re-walk; no crossing devices.
- **Delete-lifecycle guards:** Forget cancels a counting-down delete and is refused while one runs; closing the last window cancels the countdown; Rescan is blocked during a delete; collect and uncollect are blocked during a delete; Delete Anyway runs without a new countdown.
- **Root fd check:** the root CLI opens the parent fd, resolves it with `F_GETPATH` and re-runs `ProtectionRules` on the resolved parent and name, so a tampered request cannot reach a protected item through a symlinked ancestor.

**Final-review fix wave**
- **Restricted folders:** the re-walk compares the readable part with the scan first (the scan recorded unreadable folders as empty). Unchanged with unreadable folders → `.needsAdmin(started: false, verified: true)`; an item unreadable at its top level is verified only if the scan also saw nothing inside it (`fileCount == 0 && size == 0`); otherwise root re-walks it. The controller sends verified items to root with `force: true` (root still does the identity, per-directory device and `F_GETPATH` checks), so they no longer come back as "changed" and need no second prompt. A real change in the readable part stays `.changedSinceScan`.
- **Trash mode** ignores unreadable contents (moving needs only write access on the parent); the identity check still applies.
- **Admin runner:** no timeout (it started before the password prompt, and killing osascript doesn't stop root mid-delete); pipes are read as data arrives and read for at most 2 s after osascript exits. Any failure other than a cancelled prompt reads "The administrator step didn't report back. It may still be running — rescan to check." and the items stay collected.
- **Admin items file:** items travel in a 0600 JSON file in a fresh 0700 temp dir (`--items-file`), not argv, so a large batch can't exceed `ARG_MAX`; the app removes it after the run. `--env` and the file's SHA-256 (`--items-sha256`) stay in argv; root opens the file `O_NOFOLLOW`, requires a regular file and refuses it unless the hash matches, so a same-user rewrite during the password prompt is rejected.
- **Bar wording** in Trash mode says "Moving … to the Trash"; the README's Forget/Rescan description was corrected.
- After the wave: 15 commits from main (13 + 2) and 201 tests (43 MacleanKit + 114 MacleanCore + 44 MacleanApp), all passing; `scripts/build-app.sh` builds and signs the bundle.

**Manual checks still pending with the owner (before merge)**
- GUI pass: drag segment, row and Finder item to the bar; ⌘⌫; panel ×; drag row to chart; Move All; Remove All; refusal on `/System`; angle morph; Space over a panel row; chart drill after the split (Task 1).
- The sudo/admin step: delete a root-owned item in a scratch folder through the real password prompt.

**Deferred minors**
- Tree and collector: forget after a failed rescan skips the confirm; forget during a scan does not clear the collector; reordered siblings may briefly overlap in the morph; reordered entries inside a collected folder are never evicted; untested edge paths (absorb with removed beneath, uncollect of a non-collected node, generation); history fallback `replaceCurrent` can leave a duplicate back entry; `batchCollectIsFast` uses a 100 ms wall-clock bound that may flake under load.
- Protection: `ProtectionEnvironment.current()` does `fileExists` per mount and may block on a stale network mount (call per batch); home reports `.macleanItself` when the app is inside it; dev builds under `~/Library` make `~/Library` refuse.
- Deleter: `.otherDisk` found mid-removal with force loses the started flag; errno is not reset before each `readdir`; recursion runs outside `FDBudget` (EMFILE on very deep trees); parent ENOTDIR/ELOOP map to a generic failure; the Trash path race is undocumented; `trashWorks()` uses `try!`; test gaps (device mismatch, file size change).
- Delete flow and admin: `isDeleting` stays true while the summary is up, so Rescan silently no-ops until Done; `AdminDelete.resolvedRefusal` uses the default context while `Deleter` uses `.collector` (equal today: `ProtectionContext` has only `.collector`; see Before Plan 3b); the summary sheet shows in every window of the session; menu observers attach to every menu.
- Drag and drop: the NodeDrag end monitor relies on the drag loop swallowing events (unverified at runtime); mixed Finder drops give a single refusal message; Finder clipping on row drag-out is unverified.

**Before Plan 3b**
- Smart Clean reuses `Deleter`, `AdminDelete` and `ProtectionRules`; add a `.smartClean` context to `ProtectionRules` (the collector's §5.8 rules do not fit cleanup targets). `ProtectionContext` has only `.collector` today, so `AdminDelete.perform`/`resolvedRefusal` (default context) and `Deleter` (`.collector`) agree only by accident: before adding `.smartClean`, thread the deleter's context into `AdminDelete.perform` and `resolvedRefusal` (and into the helper's arguments).
- **Helper-replacement caveat:** the root helper is `Bundle.main/Contents/MacOS/maclean-scan`. If the app lives somewhere user-writable (for example `~/Applications` or a dev build), a user-level process could swap that binary before the password prompt and get it run as root. This is inherent to the osascript approach; the fix is a signed `SMAppService` privileged helper later.
- System-wide rows reuse the admin batch (one password prompt for all items) rather than prompting per row.
- Move the Trash-setting key and the summary's "changed since the scan" handling behind something both flows can share, and settle the `isDeleting`-during-summary behaviour before a second flow depends on it.
