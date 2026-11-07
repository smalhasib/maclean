# Maclean Plan 2 — App Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Maclean app: a compact start screen listing disks and starred folders, scanning with progress, and a light-and-airy main window with a ring chart, a side list, hover preview, drill-down navigation, a context menu, two window modes and full keyboard support, in light and dark.

**Architecture:** Two new targets on top of `MacleanCore`. `MacleanKit` is a library holding all UI logic that can be unit-tested without views: sunburst layout and hit-testing, palette, formatting, navigation history, the volume list and starred folders. `Maclean` is an executable holding the SwiftUI/AppKit views, windows, menus and the `ScanSession` models. `scripts/build-app.sh` bundles it into `Maclean.app` without Xcode.

**Tech Stack:** Swift 6.4 (language mode 6), SwiftPM with Command Line Tools only, SwiftUI + AppKit (`NSViewRepresentable` where needed), Quick Look (`QLPreviewPanel`), Swift Testing, `os_signpost`.

**Spec:** `docs/superpowers/specs/2026-11-07-maclean-app-shell-design.md` (binding for Plan 2). Product spec: `docs/superpowers/specs/2026-11-07-maclean-design.md`.

## Global Constraints

- macOS 14+, Swift 6 language mode, no third-party dependencies. `swift build` and `swift test` must keep working. If `swift test` fails with "plugin for module 'TestingMacros' not found", run `swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`.
- No Xcode: the app is a SwiftPM `executableTarget` named `Maclean`, bundled by `scripts/build-app.sh` into `.build/Maclean.app` with bundle id `org.maclean.Maclean` and `LSMinimumSystemVersion` 14.0, ad-hoc signed (`codesign -s -`), or signed with `$MACLEAN_SIGN_IDENTITY` when that variable is set.
- **No collect or delete UI in Plan 2:** no menu item, shortcut or drop target. The collector bar shows only its empty state, the dashed circle with "Drag files here to collect them".
- **Look:** light & airy. Semantic system colours. Body text ≥ 13 pt with `.monospacedDigit()` sizes. Names truncate in the middle, with a full-name tooltip. Red only for destructive actions. Follows the system appearance.
- **Chart:** up to 5 rings. Children are ordered largest first, clockwise from 12 o'clock. Slices under 0.6° are merged per parent into "smaller objects". Folders use 8 ordered pastel hues (blue, green, orange, purple, pink, teal, yellow, indigo), and descendants keep the top-level hue, getting lighter in light mode and darker in dark mode. Files are grey; smaller objects a lighter, translucent grey; restricted folders muted purple; undescended mount points an outlined grey. Gaps between segments are 1.5 pt in light mode and 2 pt in dark.
- **Motion:** drilling in or out animates over ~0.35 s ease-in-out, and hover over ~0.1 s. With Reduce Motion on, both become crossfades.
- **Performance, on a `/` scan:** hover highlight < 16 ms; drill animation at 60 fps; first chart frame ≤ 100 ms after a result opens. Layout covers only the visible rings. Scanning never blocks the main thread.
- **Shortcuts** (spec §6): ↑/↓, PgUp/PgDn/Home/End; Return/⌘↓/pinch-open = enter; ⌘↑/pinch-close = enclosing folder; ⌘[ / ⌘] / swipe = back/forward; ⇧⌘D = Back to Disks; Space = Quick Look; ⌘-click or ⌥⌘R = Show in Finder; ⌥⌘T = Open in Terminal; ⌥-click or ⇧⌘N = Open in New Window; ⌘R = rescan the session root; ⇧⌘R = rescan the disk; ⌘O = Scan Folder…; ⌘E = expand "smaller objects"; ⌘, = Settings. Keyboard actions apply to the item under the pointer first, otherwise to the selected row.
- Commit messages: Conventional Commits, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Folders with huge numbers of children** (a 100k-file cache folder). Layout merges them and stays fast; hover and drill stay smooth. Test in Task 2.
2. **An empty or zero-byte result** (scanning an empty folder, or a folder of 0-byte files). The chart shows an empty state with no division by zero, and the list shows "Empty folder". Test in Task 2.
3. **The current folder disappears on rescan.** The window falls back to the nearest surviving ancestor, and back/forward skips missing entries. Test in Task 3.
4. **A disk ejected while listed or while its scan is open.** The row disappears or shows "Ejected" without crashing. Actions on vanished paths (Show in Finder, Terminal, Quick Look) show an inline "No longer exists" message. Test in Task 4 (volume model) and check in Task 7.
5. **Very long, emoji or right-to-left names** in breadcrumbs, list rows and the centre label. Middle truncation, a tooltip, and no layout overflow in either appearance. Check in Task 6.

---

### Task 1: Core prerequisites for the app

**Files:**
- Modify: `Sources/MacleanCore/FileTree.swift`, `Sources/MacleanCore/FileTreeBuilder.swift` (only if needed), `Sources/MacleanCore/Scanner.swift`, `Sources/MacleanCore/ScanBoundary.swift`, `Sources/maclean-scan/main.swift`
- Create: `Sources/MacleanCore/ProcessLimits.swift`
- Test: `Tests/MacleanCoreTests/FileTreeTests.swift`, `Tests/MacleanCoreTests/ScannerTests.swift`

**Interfaces:**
- Produces:
```swift
public struct NodeChildren: RandomAccessCollection, Sendable { // Int indices, Element == NodeID, no allocation
  public var startIndex: Int { get }; public var endIndex: Int { get }
  public subscript(i: Int) -> NodeID { get }
}
extension FileTree {
  public func children(of id: NodeID) -> NodeChildren   // replaces [NodeID]; callers using .map/[i]/.count keep compiling
  public func fileCounts() -> [Int64]                    // O(n) bottom-up, indexed by NodeID.index
}
public enum ProcessLimits { public static func raiseOpenFileLimit() }  // soft = min(hard, 10240); moved from maclean-scan
extension ScanBoundary {
  public static func forRoot(_ path: String, mounts: [MountInfo]) -> ScanBoundary   // forRoot(_:) calls this with mounts()
}
public struct MountInfo: Sendable, Equatable { public let path: String; public let device: Int32; public let source: String; public let fsType: String; public init(...) }  // make public
extension Scanner {
  // the public scan overloads gain `qos: DispatchQoS.QoSClass = .userInitiated`; ioQueue reads run at that QoS
}
```
- Decisions:
  - **I/O priority:** the I/O queue is created without a fixed QoS. Each read is dispatched with `DispatchWorkItem(qos:)` from the scan's `qos`.
  - **Cancellation:** after `walk.builder.finish()`, `Scanner.scan` checks `Task.isCancelled` and throws `CancellationError`.
  - **CLI:** `maclean-scan` calls `ProcessLimits.raiseOpenFileLimit()` instead of its own code.

- [ ] **Step 1: Write failing tests**
```swift
@Test func childrenIsRangeBacked() {        // tree from sizesSumAndChildrenSortDescending fixture
  let kids = t.children(of: t.root)
  #expect(kids.count == 2 && kids[0] == t.children(of: t.root).first!)
  #expect(Array(kids).map { t.name(of: $0) } == ["a", "f"])
}
@Test func bulkFileCountsMatchPerNode() {   // 3-level fixture incl. a .hardLinkExtra file and a mount-point dir
  let counts = t.fileCounts()
  for i in 0..<t.count { #expect(counts[i] == t.fileCount(of: NodeID(index: Int32(i)))) }
}
@Test func forRootWithFakeMounts() {
  let mounts = [MountInfo(path: "/", device: 1, source: "/dev/disk3s1s1", fsType: "apfs"),
                MountInfo(path: "/System/Volumes/Preboot", device: 2, source: "/dev/disk3s2", fsType: "apfs"),
                MountInfo(path: "/Volumes/USB", device: 9, source: "/dev/disk5s1", fsType: "apfs"),
                MountInfo(path: "/System/Volumes/Update/mnt1", device: 4, source: "/dev/disk3s4s1", fsType: "apfs")]
  let b = ScanBoundary.forRoot("/", mounts: mounts)
  #expect(b.descendableMounts == ["/System/Volumes/Preboot"])   // USB is another container; snapshot excluded
  #expect(!b.allowedDevices.contains(9))
}
@Test func cancelDuringFinishThrows() async // cancel from the progress callback on the last directory → throws CancellationError
```
- [ ] **Step 2: Run** `swift test`. Expected: the new tests FAIL to compile.
- [ ] **Step 3: Implement** per the Interfaces and Decisions above.
- [ ] **Step 4: Run** `swift test`. Expected: all PASS (72 earlier tests plus the new ones).
- [ ] **Step 5: Commit** `refactor(core): app prerequisites — range children, bulk counts, mount seam, scan qos`

---

### Task 2: MacleanKit — sunburst layout and hit-testing

**Files:**
- Modify: `Package.swift` (add the `MacleanKit` library depending on `MacleanCore`, and the `MacleanKitTests` test target)
- Create: `Sources/MacleanKit/SunburstLayout.swift`
- Test: `Tests/MacleanKitTests/SunburstLayoutTests.swift`

**Interfaces:**
- Consumes: `FileTree`, `NodeID`, `NodeChildren`, `NodeFlags` (Task 1).
- Produces:
```swift
public enum SegmentKind: Sendable, Equatable { case folder, file, package, restricted, mountPoint, smallerObjects }
public struct Segment: Sendable, Equatable {
  public let node: NodeID?            // nil for a merged smallerObjects segment
  public let parent: NodeID           // the node whose children this ring slice belongs to
  public let ring: Int                // 1 = innermost ring
  public let startAngle: Double       // radians, 0 = 12 o'clock, clockwise
  public let endAngle: Double
  public let topLevelIndex: Int       // index of the ring-1 ancestor among the root's children (drives hue)
  public let kind: SegmentKind
  public let mergedSize: Int64        // smallerObjects: combined size; else the node's size
}
public struct SunburstLayout: Sendable {
  public static let maxRings = 5
  public static let minAngle = 0.6 * .pi / 180
  public init(tree: FileTree, root: NodeID, rings: Int = maxRings, minAngle: Double = minAngle)
  public let root: NodeID
  public let segments: [Segment]                       // ring 1 first, angular order within a ring
  public var isEmpty: Bool { get }                     // root size 0 or no children
  public func segment(atRadius r: Double, angle: Double, innerRadius: Double, ringWidth: Double) -> Segment?
}
```
- Decisions:
  - **Angles:** a child's angle is `span × size / parentSize`, laid out in `children(of:)` order.
  - **Merging:** the consecutive tail of children each smaller than `minAngle` merges into one `smallerObjects` segment. Because children are sorted by size, that is exactly the small ones.
  - **Where descent stops:** below packages, restricted folders, mount points and merged segments. A zero-size parent gets no children.
  - **Hit-testing:** ring = `floor((r − innerRadius) / ringWidth) + 1`, then a binary search on angle within that ring.

- [ ] **Step 1: Write failing tests** (fixtures built with `FileTreeBuilder`)
```swift
@Test func anglesAreProportional()   // root children 300/100 → ring-1 spans 3π/2 and π/2, starting at 0
@Test func tinyTailIsMerged()        // children 1000, 1000, 1, 1, 1 → 2 folder segments + 1 smallerObjects with mergedSize 3
@Test func hugeFolderStaysBounded() {  // one folder with 100_000 equal 1-byte files and one 10 MB file
  let l = SunburstLayout(tree: t, root: t.root)
  #expect(l.segments.count < 2_000)
}
@Test func stopsAtPackagesRestrictedAndMounts()   // children of .package/.restricted/.mountPoint nodes never appear
@Test func emptyTreeIsEmpty()        // root with only 0-byte files → isEmpty == true, no NaN angles
@Test func ringsAreCapped()          // 7-deep chain → max ring == 5
@Test func hitTestFindsSegment()     // centre of ring 2 at a known angle → that segment; radius inside the hole → nil; beyond ring 5 → nil
@Test func layoutIsFast()            // 1M-node synthetic tree: layout for the root in < 200 ms in a debug test build
```
- [ ] **Step 2: Run** `swift test --filter SunburstLayoutTests`. Expected: FAIL.
- [ ] **Step 3: Implement** `SunburstLayout` as decided.
- [ ] **Step 4: Run** `swift test`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(kit): sunburst layout and hit-testing`

---

### Task 3: MacleanKit — palette, formatting, navigation history

**Files:**
- Create: `Sources/MacleanKit/Palette.swift`, `Sources/MacleanKit/SizeText.swift`, `Sources/MacleanKit/NavigationHistory.swift`
- Test: `Tests/MacleanKitTests/PaletteTests.swift`, `Tests/MacleanKitTests/NavigationHistoryTests.swift`, `Tests/MacleanKitTests/SizeTextTests.swift`

**Interfaces:**
- Consumes: `Segment`, `SegmentKind` (Task 2).
- Produces:
```swift
public enum Appearance: Sendable { case light, dark }
public struct RGB: Sendable, Equatable { public let r, g, b: Double; public var relativeLuminance: Double { get } } // WCAG luminance
public enum Palette {
  public static let hueCount = 8
  public static func color(kind: SegmentKind, topLevelIndex: Int, ring: Int, appearance: Appearance, highContrast: Bool = false) -> RGB
  public static func segmentGap(appearance: Appearance, highContrast: Bool) -> Double   // 1.5 / 2.0, thicker with highContrast
}
public enum SizeText { public static func string(_ bytes: Int64) -> String }   // ByteCountFormatter .file, e.g. "306.6 GB"
public struct NavigationHistory: Sendable, Equatable {
  public init(rootPath: String)
  public private(set) var current: String                 // absolute path
  public var canGoBack: Bool { get }; public var canGoForward: Bool { get }
  public mutating func visit(_ path: String)              // drops forward stack
  public mutating func back(); public mutating func forward()
  public func enclosing(rootPath: String) -> String?      // nil at the tree root
  public mutating func remap(exists: (String) -> Bool)    // after rescan: current → nearest existing ancestor; drop missing back/forward entries
}
```
- [ ] **Step 1: Write failing tests**
```swift
@Test func neighbouringHuesDifferInLightness() {
  for a in [Appearance.light, .dark] { for i in 0..<Palette.hueCount {
    let x = Palette.color(kind: .folder, topLevelIndex: i, ring: 1, appearance: a)
    let y = Palette.color(kind: .folder, topLevelIndex: (i + 1) % Palette.hueCount, ring: 1, appearance: a)
    #expect(abs(x.relativeLuminance - y.relativeLuminance) >= 0.04) } }
}
@Test func ringsLightenInLightDarkenInDark()   // luminance(ring 3) > ring 1 in light; < ring 1 in dark
@Test func filesAreGreyAndRestrictedPurple()   // file r≈g≈b; restricted b > g
@Test func historyBackForward()                // visit a, b, c; back → b; back → a; forward → b; visit d → canGoForward false
@Test func remapFallsBackToAncestor()          // current /r/a/b/c; only /r/a exists → current /r/a; missing entries removed from back stack
@Test func sizeText()                          // 306_600_000_000 → "306.6 GB"; 0 → "Zero KB"
```
- [ ] **Step 2: Run** `swift test --filter "PaletteTests|NavigationHistoryTests|SizeTextTests"`. Expected: FAIL.
- [ ] **Step 3: Implement.** The builder picks palette values within the Global Constraints' rules, defined in OKLCH or HSL, converted to sRGB.
- [ ] **Step 4: Run** `swift test`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(kit): palette, size text and navigation history`

---

### Task 4: MacleanKit — volume list and starred folders

**Files:**
- Create: `Sources/MacleanKit/VolumeList.swift`, `Sources/MacleanKit/StarredFolders.swift`
- Test: `Tests/MacleanKitTests/VolumeListTests.swift`, `Tests/MacleanKitTests/StarredFoldersTests.swift`

**Interfaces:**
- Consumes: `MountInfo` (Task 1).
- Produces:
```swift
public struct VolumeEntry: Sendable, Equatable, Identifiable {
  public let id: String            // mount path, e.g. "/" or "/Volumes/USB"
  public let name: String          // "Macintosh HD" for "/"
  public let scanPath: String      // "/" for the startup disk, else the mount path
  public let isNetwork: Bool, isDiskImage: Bool
}
public enum VolumeList {
  /// Filters mounts to what the start screen lists (spec §5.1): startup disk, internal/external disks, disk images,
  /// network shares; hides /System/Volumes/*, Recovery, autofs ("map …" sources / fsType "autofs"), Time Machine (`/Volumes/.timemachine`, `com.apple.TimeMachine` paths).
  public static func entries(from mounts: [MountInfo], volumeName: (String) -> String) -> [VolumeEntry]
}
public struct Capacity: Sendable, Equatable { public let total: Int64; public let freeIncludingPurgeable: Int64 }
public enum VolumeCapacity { public static func of(path: String) -> Capacity? }  // volumeTotalCapacity + volumeAvailableCapacityForImportantUsage
@MainActor public final class StarredFolders {
  public init(defaults: UserDefaults, key: String = "starredFolders")
  public private(set) var paths: [String]
  public func star(_ url: URL); public func unstar(_ path: String)
  public func resolve() -> [String]     // re-resolves bookmarks; moved folders get their new path; missing ones are dropped
}
```
- [ ] **Step 1: Write failing tests**
```swift
@Test func startupAndExternalListedSystemHidden() {
  // mounts: "/", "/System/Volumes/Data", "/System/Volumes/Preboot", "/Volumes/Recovery", "/Volumes/USB", "/Volumes/Share" (smbfs, "//u@h/share"), "/net" (autofs)
  // → ids ["/", "/Volumes/USB", "/Volumes/Share"]; "/" name from volumeName("/") ; Share isNetwork
}
@Test func ejectedVolumeDisappears()     // same mounts minus /Volumes/USB → entry gone
@Test func starRoundTrip()               // UserDefaults(suiteName: UUID) ; star temp dir; new StarredFolders on same suite → paths contains it
@Test func movedStarredFolderFollows()   // star temp/a; rename to temp/b; resolve() → [".../b"]
@Test func deletedStarredFolderDropped() // star then delete → resolve() == []
```
- [ ] **Step 2: Run** `swift test --filter "VolumeListTests|StarredFoldersTests"`. Expected: FAIL.
- [ ] **Step 3: Implement.** Bookmarks use `URL.bookmarkData(options: [])` (no security scope: the app isn't sandboxed).
- [ ] **Step 4: Run** `swift test`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(kit): volume list filtering and starred folders`

---

### Task 5: App target, scan sessions and the start screen

**Files:**
- Modify: `Package.swift` (add `executableTarget` `Maclean` depending on `MacleanKit`, `MacleanCore`)
- Create: `Sources/Maclean/MacleanApp.swift`, `Sources/Maclean/ScanSession.swift`, `Sources/Maclean/SessionRegistry.swift`, `Sources/Maclean/StartView.swift`, `Sources/Maclean/VolumeRowView.swift`, `scripts/build-app.sh`, `Resources/Info.plist`
- Modify: `README.md` (Run the app: `swift run Maclean` or `scripts/build-app.sh && open .build/Maclean.app`)

**Interfaces:**
- Consumes: `Scanner.scan(path:qos:progress:)`, `ProcessLimits.raiseOpenFileLimit()` (Task 1); `VolumeList`, `VolumeCapacity`, `StarredFolders`, `SizeText`, `NavigationHistory` (Tasks 3–4).
- Produces:
```swift
@MainActor @Observable final class ScanSession: Identifiable {
  enum State { case scanning(bytes: Int64, expected: Int64?), finished(FileTree), failed(String), cancelled }
  let id: UUID; let rootPath: String
  private(set) var state: State
  func start(); func cancel()                  // cancel shows "Stopping…" until the scan task ends
  func rescan()                                // new tree replaces the old; observers remap history by path
}
@MainActor @Observable final class SessionRegistry {
  func session(for path: String) -> ScanSession?          // by canonical path
  func startScan(path: String) -> ScanSession             // always fresh (Scan, Scan Folder…, starred Scan)
  func forget(path: String)
}
```
- Decisions:
  - **Launch:** at startup the app calls `ProcessLimits.raiseOpenFileLimit()`.
  - **Start screen:** `StartView` lists `VolumeList.entries` (refreshed on `NSWorkspace.didMountNotification`/`didUnmountNotification`), then starred folders, then **Scan Folder…** (⌘O, an `NSOpenPanel` that picks directories).
    - It accepts dropped folders, and the app accepts folders dropped on its Dock icon (`application(_:open:)`).
    - Each row has Scan/View, a ▾ menu (Rescan, Forget Scan Result; Task 7 adds Show in Finder and Get Info), inline progress ("Scanning… 182 GB", expected = used bytes for volumes, nil for folders), Cancel, and an inline error.
    - Dropping a folder onto the Starred section stars it; dropping one anywhere else on the window scans it. Each starred row's context menu has Unstar.
  - **Window size:** compact, minimum 520 × 300.
  - **After a scan finishes:** for this task, show the finished tree's root size and top children in a plain placeholder view. Task 6 replaces it with the main window.
  - **Bundling:** `build-app.sh` builds release, creates `.build/Maclean.app/Contents/{MacOS,Resources,Info.plist}`, copies the binary, and signs it (`codesign --force -s "${MACLEAN_SIGN_IDENTITY:--}"`).
- [ ] **Step 1: Build check** `swift build`. Expected: succeeds with the new target.
- [ ] **Step 2: Implement** per Decisions.
- [ ] **Step 3: Verify (computer use, read-only):**
  - `scripts/build-app.sh && open .build/Maclean.app`. The start screen lists "Macintosh HD" with "494 GB · NN GB free".
  - Scan a small folder via Scan Folder… (e.g. the repo's `Tests`): progress shows, then the placeholder shows its top children.
  - Start a `/` scan and press Cancel: "Stopping…", then the row returns to Scan.
  - Star a folder; it survives an app relaunch.
  - Screenshot each step into the report.
- [ ] **Step 4: Run** `swift test`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(app): app target, scan sessions and start screen`

---

### Task 6: Main window — chart, side list, breadcrumbs, hover and drill

**Files:**
- Create: `Sources/Maclean/ResultView.swift`, `Sources/Maclean/SunburstView.swift`, `Sources/Maclean/SideListView.swift`, `Sources/Maclean/BreadcrumbBar.swift`, `Sources/Maclean/CollectorBar.swift`, `Sources/Maclean/ResultViewModel.swift`, `Sources/Maclean/Timings.swift`

**Interfaces:**
- Consumes: `SunburstLayout`, `Segment` (Task 2); `Palette`, `SizeText`, `NavigationHistory` (Task 3); `ScanSession` (Task 5); `FileTree.fileCounts()`, `children(of:)` (Task 1).
- Produces:
```swift
@MainActor @Observable final class ResultViewModel {
  init(session: ScanSession, startPath: String? = nil)
  var history: NavigationHistory
  var currentNode: NodeID { get }; var layout: SunburstLayout { get }   // recomputed on navigation only
  var hovered: NodeID?; var selected: NodeID?
  var listTarget: NodeID { get }                                        // hovered ?? currentNode (what the side list shows)
  var actionTarget: NodeID? { get }                                     // hovered ?? selected (keyboard actions)
  var expandSmallerObjects: Bool                                        // persisted "Always Expand" default via UserDefaults
  func open(_ node: NodeID); func goUp(); func back(); func forward()
}
enum Timings { static let enabled: Bool; static func mark(_ name: StaticString, _ ms: Double) } // MACLEAN_TIMINGS=1 → os_signpost + stderr
```
- Decisions:
  - **Chart:** `SunburstView` draws `layout.segments` with Core Graphics in an `NSView`, wrapped in `NSViewRepresentable`. The builder may use SwiftUI `Canvas` instead if it meets the performance constraints.
    - Hover uses an `NSTrackingArea` plus hit-testing, and the hovered segment is redrawn highlighted.
    - Animation interpolates `startAngle`/`endAngle`/`ring` between the old and new layouts.
    - The centre disc shows the size (large) and name (small). Clicking it calls `goUp()`.
  - **Side list:** header, then rows (dot, name, size), then "smaller objects…" (it expands when `expandSmallerObjects` is on or it's clicked). Hovering a row sets `hovered`, so its segment highlights too. At volume roots it also shows a divider and the "free space" and "free + purgeable" rows. An empty result shows "Empty folder".
  - **Breadcrumbs:** "Disks" plus path components from the session root, collapsing the middle into "…" with a menu.
  - **Collector bar:** the empty state only.
  - **Wiring:** a finished `ScanSession` in one-window mode swaps `StartView` for `ResultView` in the same window. The window animates its size from compact to at least 760 × 520.
- [ ] **Step 1: Implement** per Decisions; replace Task 5's placeholder.
- [ ] **Step 2: Verify (computer use, read-only):**
  - Scan `/`. Hover segments at rings 1 and 3: the side list switches to the hovered item.
  - Click to drill in two levels; the breadcrumbs update. Click the centre to go up.
  - Expand "smaller objects". A `.app` is shown solid.
  - Repeat in dark mode (System Settings › Appearance) and with Reduce Motion on.
  - Check Review Focus 5 with a temp folder of long, emoji and Arabic-named files.
  - With `MACLEAN_TIMINGS=1 .build/Maclean.app/Contents/MacOS/Maclean`, record the hover, frame and first-frame numbers against the performance constraints.
  - Screenshots go in the report.
- [ ] **Step 3: Run** `swift test`. Expected: PASS.
- [ ] **Step 4: Commit** `feat(app): main window with ring chart, side list and navigation`

---

### Task 7: Actions, context menu, window modes, menus and shortcuts

**Files:**
- Create: `Sources/Maclean/Actions.swift`, `Sources/Maclean/QuickLookBridge.swift`, `Sources/Maclean/AppCommands.swift`, `Sources/Maclean/SettingsView.swift`, `Sources/Maclean/WindowRouter.swift`
- Modify: `Sources/Maclean/ResultView.swift`, `Sources/Maclean/StartView.swift`, `Sources/Maclean/MacleanApp.swift`

**Interfaces:**
- Consumes: `ResultViewModel` (Task 6), `SessionRegistry`/`ScanSession` (Task 5), `StarredFolders` (Task 4).
- Produces:
```swift
@MainActor enum Actions {
  static func showInFinder(_ path: String) -> ActionResult          // NSWorkspace.activateFileViewerSelecting
  static func openInTerminal(_ path: String) -> ActionResult        // folder, or file's parent; open -a Terminal
  static func getInfo(_ path: String) -> ActionResult               // Finder "open information window" via NSAppleScript
  static func launchDiskUtility()
}
enum ActionResult: Equatable { case ok, missing }                   // .missing → inline "No longer exists" banner (Review Focus 4)
@MainActor final class WindowRouter {   // reads Settings "openEachScanInOwnWindow" (@AppStorage, default false)
  func show(session: ScanSession, at path: String?, forceNewWindow: Bool)   // one-window vs window-per-scan per spec §5.4; one window per (tree, node)
}
```
- Decisions:
  - **Context menu** (segment or row): Expand / Show Package Contents / Preview / Show in Finder / Open in Terminal / Open in New Window / Star or Unstar Folder.
  - **Quick Look:** Space toggles `QLPreviewPanel` for `actionTarget`.
  - **Menus:** the menu bar matches spec §6 exactly, with the shortcuts from Global Constraints, built through SwiftUI `.commands`.
  - **Gestures:** pinch and swipe come from `NSEvent` magnify/swipe in `SunburstView`.
  - **Rescan:** ⌘R rescans the session root. Every window on that session calls `history.remap`. ⇧⌘R rescans the session's volume.
  - **Settings:** a General tab with the toggle "Open each scan in its own window".
- [ ] **Step 1: Implement** per Decisions.
- [ ] **Step 2: Verify (computer use, read-only; no deleting):**
  - Every row of the spec §6 table works on a `/` scan, using both the keyboard and the menu bar.
  - Context menu items work; Quick Look opens a file.
  - Toggle the setting: Scan or View opens a separate window. Merge All Windows makes tabs. Open in New Window works in both modes.
  - ⌘R keeps the current folder.
  - Show in Finder on a folder deleted after the scan (create and delete a temp folder, then scan its parent first) shows "No longer exists".
  - Screenshots go in the report.
- [ ] **Step 3: Run** `swift test`. Expected: PASS.
- [ ] **Step 4: Commit** `feat(app): actions, context menu, window modes, menus and shortcuts`

---

### Task 8: Accessibility pass and full checklist

**Files:**
- Modify: `Sources/Maclean/SunburstView.swift`, `Sources/Maclean/SideListView.swift`, `Sources/Maclean/StartView.swift`
- Create: `docs/manual-checklist.md`, the spec §9 checklist as checkboxes, kept for later plans.

- Decisions:
  - **VoiceOver:** list rows read "<name>, <folder|file|package>, <size>". The chart is one element with its ring-1 segments as children, using the same labels.
  - **Increase Contrast:** uses `Palette`'s high-contrast gaps and full-contrast labels.
  - **Keyboard in the chart:** ←/→ moves between siblings, ↑/↓ moves out and in, and Tab moves between toolbar, list and chart.
- [ ] **Step 1: Implement** per Decisions.
- [ ] **Step 2: Verify (computer use):**
  - Run every item in `docs/manual-checklist.md` in light and dark mode, and record pass or fail with screenshots in the report.
  - For VoiceOver, ask the owner to turn it on (⌘F5) and confirm three list rows read as "<name>, <kind>, <size>". This changes a system setting, so the builder doesn't toggle it.
  - Report any item that computer use can't drive.
- [ ] **Step 3: Run** `swift test`. Expected: PASS.
- [ ] **Step 4: Commit** `feat(app): accessibility pass and manual checklist`
