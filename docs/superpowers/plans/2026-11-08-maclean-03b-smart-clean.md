# Maclean Plan 3b: Smart Clean Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A check runs at launch (and on ⇧⌘K). It finds cleanable caches, logs, build output, leftovers and system-wide junk, and lists them grouped and tiered in a review sheet. Only what the user ticks and confirms gets deleted, through Plan 3a's delete engine.

**Architecture:**
- **MacleanCore** gains three things:
  - a timestamp-aware single-subtree `Measurer`;
  - a `.smartClean` protection context;
  - the rule catalog plus a generic `CleanEngine` that expands patterns, measures, applies age, owner and protection conditions, and classifies items into candidates and skipped items.
- **Runtime probes** sit behind a `CleanProbes` protocol, so the engine is tested against temp folders with fake probes:
  - running apps, installed apps and open files;
  - process working directories and git.
- **The app** gains a `SmartCleanController` and three pieces of UI: the start-screen card, the review sheet, and the Settings tab.
  - Deletion goes through a `DeleteBatch` extracted from `DeleteController`, so both flows share the run loop, the admin escalation and the summary.
  - System-wide items use the admin batch, with one password prompt per Clean.
  - The root helper accepts a Smart Clean item only if it matches a catalog rule that needs administrator rights, and re-checks that rule's age itself.

**Tech Stack:**
- Swift 6.4 (language mode 6), SwiftPM with Command Line Tools only.
- SwiftUI + AppKit, Swift Testing.
- `getattrlistbulk`, `NSWorkspace`, `libproc` (`proc_listpids`, `proc_pidinfo`, `proc_pidpath`), and `git` via `Process`.
- `osascript` for the admin prompt.

**Spec:** `docs/superpowers/specs/2026-11-07-maclean-collector-cleanup-design.md`, Part 2 (§5–6) and §6.4 "Smart Clean context". This spec is binding. Plan 3a's "Before Plan 3b" notes in `docs/superpowers/plans/2026-11-07-maclean-03a-collector-delete.md` set Task 1.

## Global Constraints

- **Toolchain:** macOS 14+, Swift 6 language mode, no third-party dependencies.
  - Tests: `swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing` (called **T** below).
  - `@State` doesn't compile; use `State(initialValue:)` in `init`. `@Observable` works.
- **Never delete real user files.** Engine and delete tests use `TempDir` fixtures and a fake home. The catalog is tested by pattern matching on path strings, never by running it against the real `~` with a real deleter. Manual checks use `~/maclean-scratch` only.
- **Nothing copied from mole** (GPL-3.0). Lists such as protected bundle ids and the dangerous-path corpus are Maclean's own.
- **The launch check never asks for a password and never deletes.** Deletion happens only after Review → Clean → the confirmation alert.
- **Default ticks:** Safe items ticked, Review items unticked, Info items have no checkbox.
- **Unknown means keep:** a probe that fails or times out sends the item to Skipped, never to the candidates.
- **Deletion mode:** the shared `MoveToTrashInsteadOfDeleting` key applies, except that the Trash category is always deleted permanently.
- **Time budget:** 5 s per target. A target over budget shows "size unknown" and is unticked.
- **UserDefaults keys:**
  - `smartClean.checkAtLaunch` (Bool, default `true`)
  - `smartClean.neverClean` ([String] of absolute paths)
  - `smartClean.disabledCategories` ([String] of `CleanRule.Category` raw values)
  - `smartClean.projectRoots` ([String], extra search roots)
- **Copy:**
  - Card: "**<size>** can be cleaned" / "Checking for cleanable items…" / "Nothing to clean right now".
  - Header: "<size> selected of <size> found".
  - Alert: "Delete <n> items (<size>)?" with "They will be deleted permanently." or "They will be moved to the Trash.", plus "Some items need your administrator password." when relevant.
  - Red is used only for Clean.
- **Look:** Plan 2's light & airy style. Both appearances. Body text ≥ 13 pt with `.monospacedDigit()` sizes. Middle truncation with a tooltip. Keyboard reachable.
- **Commits:** Conventional Commits, with no AI attribution trailer. Never push.

**Left out on purpose:**
- §6.7's optional reuse of an open scan result. The check always measures. Add the reuse if the check exceeds 10 s on the owner's Mac.
- The full Full Disk Access onboarding, which is Plan 4. This plan only links to System Settings.

## Review Focus

1. **The owning app is open, or opens between the check and Clean.** At check time the item goes to Skipped as "app running". The owner probe re-runs just before each delete and skips the item if its app is open. Tests in Task 4 and Task 8.
2. **A Safe cache grows between the check and Clean.** It's still deleted unless it grew more than 10%. A Review item that changed goes to "changed since the check". Tests in Task 1 and Task 8.
3. **A never-clean entry that is an ancestor or descendant of a target.** Nothing at, above or below it is offered, and it shows in Skipped as "never-clean list". Test in Task 3.
4. **A symlinked ancestor**, for example `~/Library/Caches` replaced by a link to `/`. It's refused in the Smart Clean context, and nothing outside the real target is measured or deleted. Tests in Task 3 and Task 2.
5. **The password prompt is cancelled for system items.** Those items are listed as "skipped: administrator password not given", and every user-level item still proceeds. Test in Task 8.

---

### Task 1: Shared delete engine (Plan 3a follow-ups, no visible change)

**Files:**
- Create: `Sources/Maclean/DeleteBatch.swift`
- Modify:
  - `Sources/MacleanCore/Deleter.swift`
  - `Sources/MacleanCore/ProtectionRules.swift` (enum case only)
  - `Sources/MacleanCore/AdminDelete.swift`
  - `Sources/maclean-scan/main.swift`
  - `Sources/Maclean/DeleteController.swift`
  - `Sources/Maclean/ScanSession.swift`
- Test:
  - `Tests/MacleanCoreTests/DeleterTests.swift`
  - `Tests/MacleanCoreTests/AdminDeleteTests.swift`
  - `Tests/MacleanAppTests/DeleteControllerTests.swift`
  - `Tests/MacleanAppTests/DeleteBatchTests.swift`

**Interfaces:**
- Produces:
  - `ProtectionContext { case collector, smartClean }`. Only the case is added here. `.smartClean` refusals arrive in Task 3, and until then it uses the collector rules.
  - `DeleteRequest.tolerance: ChangeTolerance` (default `.strict`), with `public enum ChangeTolerance: String, Codable, Sendable { case strict, cache }`.
    - `.cache` means "changed" only if the size grew by more than 10% (`size > scanned * 11 / 10`). A changed file count or a shrink is fine.
    - The init gains `tolerance: ChangeTolerance = .strict`.
  - `Deleter.init(mode:environment:context: ProtectionContext = .collector)`. The deleter uses its context for every refusal check.
  - `AdminDelete.arguments(itemsFile:sha256:environment:context:)` adds `--context collector|smart-clean`. `parse` returns `(items, environment, context)` and requires exactly 9 arguments. `perform` and `resolvedRefusal` take the deleter's context.
  - `@MainActor final class DeleteBatch`:
    - `init(mode: DeleteMode, context: ProtectionContext, makeDeleter: @escaping (DeleteMode, ProtectionContext) -> any DeleterProtocol, admin: any AdminRunning)`.
    - `func run(_ items: [DeleteBatch.Item], shouldStop: () -> Bool, progress: (Int, Int) -> Void, beforeEach: (Item) -> String?) async -> DeleteReport`.
    - `struct Item { let request: DeleteRequest; var force: Bool; var mode: DeleteMode? }`. A non-nil `mode` overrides the batch mode; the Trash category uses this.
    - `beforeEach` returns a failure reason to skip an item, which is how owner probes get re-checked.
    - `var awaitingAdmin: Bool` (observable).
    - It holds the sequential loop, Stop between items, the `.needsAdmin` queue with `force` for started or verified items, the single admin call through the items file, and the report mapping now in `DeleteController.escalate`/`apply`.
  - `DeleteController` keeps its public surface and behaviour and delegates the run to `DeleteBatch`.
  - **`isDeleting` ruling:** `ScanSession.isDeleting` becomes false when the summary appears, so Rescan works while the summary is up. The summary's Delete Anyway sets it true again for its run.

- [ ] **Step 1: Tests**

```swift
// DeleterTests
@Test func cacheToleranceAllowsSmallGrowth() async throws   // scanned 100 KiB, add 8 KiB → .deleted
@Test func cacheToleranceRefusesLargeGrowth() async throws  // scanned 100 KiB, add 20 KiB → .changedSinceScan
@Test func cacheToleranceIgnoresFileCountChange() async throws
// AdminDeleteTests
@Test func contextRoundTrips() throws   // .smartClean → "--context","smart-clean" → parse(...).context == .smartClean
@Test func parseRejectsUnknownContext() throws
// DeleteBatchTests (fake deleter + fake admin, as in DeleteControllerTests)
@Test func beforeEachSkipsItemWithReason() async   // report.failed[path] == reason, deleter never called for it
@Test func perItemModeOverridesBatchMode() async   // batch .trash, item mode .permanent → deleter made with .permanent
@Test func cancelledAdminKeepsUserItems() async    // user item .deleted, admin item failed == DeleteController.adminNotGiven
// DeleteControllerTests
@Test func rescanAllowedWhileSummaryShown() async  // after run → phase .summary, session.isDeleting == false
```

- [ ] **Step 2:** Run T. The new tests fail to compile or fail.
- [ ] **Step 3:** Implement as in Interfaces. The helper passes `parsed.context` to its `Deleter`. Every existing `DeleteControllerTests` test must pass unchanged, apart from the `isDeleting` ruling.
- [ ] **Step 4:** Run T. Everything passes.
- [ ] **Step 5:** Commit: `refactor: extract delete batch, thread protection context`.

---

### Task 2: Measurer (size, count and newest time of one subtree)

**Files:**
- Create: `Sources/MacleanCore/Measurer.swift`
- Modify: `Sources/MacleanCore/DirectoryReader.swift`
- Test: `Tests/MacleanCoreTests/MeasurerTests.swift`

**Interfaces:**
- Produces:
  - `RawEntry.modified: Int64`, the larger of the entry's mtime and ctime in Unix seconds.
    - Request `ATTR_CMN_MODTIME | ATTR_CMN_CHGTIME`.
    - Attributes come back in bit order, so the two `timespec`s sit between `OBJTYPE` and `FILEID`.
  - `public struct Measurement: Sendable, Equatable, Codable { size: Int64; fileCount: Int64; newest: Date; inode: UInt64; device: Int32; isDirectory: Bool; restricted: Bool }`
  - `public final class MeasureContext: @unchecked Sendable` (lock-protected). It counts each hard-linked inode and each clone ID once across every `measure` call that shares it, which is the scanner's rule.
  - `public enum MeasureError: Error, Equatable { case timedOut, notFound, unreadable }`
  - `public enum Measurer { static func measure(_ path: String, context: MeasureContext, deadline: ContinuousClock.Instant? = nil) throws(MeasureError) -> Measurement }`
    - The item itself is `lstat`ed. A symlink or file measures as itself, and a link is never followed.
    - Directories are walked with `DirectoryReader` relative to the parent fd.
    - It never crosses a device and never descends into a mount point.
    - An unreadable subfolder sets `restricted`.
    - An unreadable top level throws `.unreadable`.
    - The deadline is checked once per directory.

- [ ] **Step 1: Tests** (all on `TempDir`)

```swift
@Test func measuresSizeCountAndNewest()      // 2 files of 4096 → size ≥ 8192, fileCount == 2; touch one to now-1d via utimes, other now-10d → newest ≈ now-1d (±2 s)
@Test func directoryMtimeCounts()            // empty subdir created now, files 10 d old → newest ≈ now
@Test func symlinkIsNotFollowed()            // link → big file elsewhere: measure(link).fileCount == 1, size < 4096
@Test func hardLinkCountedOncePerContext()   // a and b hard links, measure(a)+measure(b) with one context: second size == 0
@Test func restrictedSubfolderFlagged()      // chmod 000 sub → restricted == true
@Test func unreadableTopThrows()             // chmod 000 item → throws .unreadable
@Test func pastDeadlineThrowsTimedOut()      // deadline: .now - .seconds(1) → .timedOut
```

- [ ] **Step 2:** Run T. The new tests fail.
- [ ] **Step 3:** Implement. Existing scanner tests must still pass after the `DirectoryReader` change.
- [ ] **Step 4:** Run T. Everything passes.
- [ ] **Step 5:** Commit: `feat: add subtree measurer with timestamps`.

---

### Task 3: ProtectionRules, Smart Clean context

**Files:**
- Modify: `Sources/MacleanCore/ProtectionRules.swift`
- Test: `Tests/MacleanCoreTests/ProtectionRulesTests.swift`, plus `Tests/MacleanCoreTests/Resources/dangerous_paths.txt` if entries are needed

**Interfaces:**
- Produces:
  - New `Refusal` cases, with messages: `criticalRoot`, `personalData`, `neverClean`, `protectedApp`, `appleSystem`.
  - `ProtectionEnvironment.neverClean: [String]`. It's an init parameter with default `[]`, and it's Codable, so it travels in `--env`. Root may take it from the app because it can only deny.
  - `public static let protectedBundlePrefixes: [String]` (password managers, input methods, VPNs, security tools; Maclean's own list).
  - `public static let appleAllowlist: [String]` contains three groups:
    - the §6.2 Apple cache list verbatim, where `*` is a glob, as in `com.apple.WebKit.*`;
    - the §6.2a Apple names: `com.apple.iconservices.store`, `com.apple.metal`, `com.apple.metalfe`, `com.apple.gpuarchiver` and `com.apple.idleassetsd`;
    - `com.apple.mail`, allowed only when the path continues into `Data/Library/Mail Downloads`.
- `refusal(for:context: .smartClean, in:)` refuses, in this order (the §6.4 Smart Clean context):
  1. Every collector refusal.
  2. Any ancestor that is a symlink. Resolve with `realpath` on the parent and re-run the checks on the resolved path; the resolved path can only deny.
  3. Critical roots: `/`, `/Applications`, `/Users`, `/Users/<anyone>`, `/Users/Shared`, `/Volumes`, `/opt/homebrew`, `/etc`, `/private/etc`, `/private/var/db`, `~/Library`, `~/Library/Caches`, `~/Library/Containers`, `~/Library/Application Support`, `~/Library/Logs`, `~/Library/Developer`, `/Library/Caches`, `/Library/Logs`, `/private/var/log`. The roots themselves are refused; their children are fine.
  4. Personal data (§6.4 list): Keychains, Accounts, Mail except `Mail Downloads`, Messages, Calendars, Contacts, `*.photoslibrary`, `Mobile Documents`, and in Safari `History.db`, `Bookmarks.plist` and `LocalStorage`. Browser profile data other than `Cache`, `Code Cache`, `GPUCache`, `ShaderCache`, `DawnCache` and `GrShaderCache` is refused too.
  5. Never-clean: the path equals an entry, or is an ancestor or descendant of one, compared NFC and case-insensitively.
  6. A path component that starts with a protected prefix.
  7. A component starting with `com.apple.` that isn't in `appleAllowlist`.
  8. Anything under `/private` outside the §6.2a `/private` allowlist, which is refused as `.criticalRoot`. The allowlist is `/private/var/log/…`, `/private/var/db/diagnostics/…`, `/private/var/db/reportmemoryexception/…`, and the current user's `/private/var/folders/<x>/<y>/…`, found with `confstr(_CS_DARWIN_USER_CACHE_DIR)` and taking its parent.

- [ ] **Step 1: Tests**

```swift
@Test func smartCleanRefusesEveryCorpusEntry()          // every dangerous_paths.txt line → refusal(.smartClean) != nil
@Test func smartCleanAllowsCatalogShapes()              // ~/Library/Caches/com.example.app, ~/Library/Logs/x, /Library/Logs/DiagnosticReports/a.ips, ~/Library/Caches/com.apple.Safari → nil
@Test func criticalRootsRefusedChildrenAllowed()        // ~/Library/Caches → .criticalRoot; ~/Library/Caches/foo → nil
@Test func neverCleanCoversAncestorsAndDescendants()    // entry ~/Library/Caches/A/b: …/A (ancestor), …/A/b, …/A/b/c → .neverClean; …/B → nil
@Test func symlinkedAncestorRefused()                   // TempDir home with Library/Caches → link to "/" : refusal(home/Library/Caches/System) != nil
@Test func appleComponentsNeedAllowlist()               // ~/Library/Caches/com.apple.Safari nil; com.apple.bird → .appleSystem
@Test func protectedAppRefused()                        // ~/Library/Caches/com.1password.1password → .protectedApp
@Test func personalDataRefused()                        // Mail/V10, Mail Downloads allowed; Chrome/Default/History refused, Chrome/Default/Cache allowed
@Test func collectorContextUnchanged()                  // existing collector tests untouched and passing
```

- [ ] **Step 2:** Run T. The new tests fail.
- [ ] **Step 3:** Implement. Add corpus entries only if a category is missing, such as `/private/var/db/uuidtext` or `~/Library/Keychains`.
- [ ] **Step 4:** Run T. Everything passes.
- [ ] **Step 5:** Commit: `feat: add smart clean protection context`.

---

### Task 4: Rule catalog and engine

**Files:**
- Create:
  - `Sources/MacleanCore/CleanRule.swift` (types)
  - `Sources/MacleanCore/CleanCatalog.swift` (the v1 rows)
  - `Sources/MacleanCore/CleanEngine.swift`
- Test: `Tests/MacleanCoreTests/CleanEngineTests.swift`, `Tests/MacleanCoreTests/CleanCatalogTests.swift`

**Interfaces:**
- Produces:

```swift
public struct CleanRule: Sendable, Identifiable {
    public enum Category: String, CaseIterable, Sendable, Codable {
        case appCaches, browsers, logs, developer, projectLeftovers, oldInstallers, removedApps,
             windowState, trash, mailAttachments, systemLogs, systemCaches, systemServices, largeData
    }
    public enum Tier: Int, Sendable, Codable, Comparable { case info, review, safe }
    public enum Unit: Sendable { case folder, eachChild }
    public enum Owner: Sendable { case none, bundleID(String), childNameIfBundleID, containerBundleID, appSupportFolder, processName(String) }
    public enum Special: Sendable { case none, keepNewest(Int), derivedData, removedAppLeftover, projectArtifacts, launchdOrphan, macOSInstaller, downloadsInstaller }
    public let id: String
    public let category: Category
    public let pattern: String          // "~/…" or absolute; at most one "*" segment; {a,b} braces allowed
    public let unit: Unit
    public let ageTiers: [(days: Int, tier: Tier)]   // newest-first match: first entry whose days ≤ age wins; none → Skipped .recent
    public let owner: Owner
    public let fileFilter: [String]?    // glob names for files-only rows (e.g. *.log, *.gz); nil = any
    public let exclude: [String]        // glob names never offered (e.g. *.incomplete)
    public let requiresAdmin: Bool
    public let requireNotOpen: Bool     // /private/var/log files, idleassetsd tmp, containers: probes.isOpen must be false
    public let special: Special
    public let reason: String
}
public struct CleanCandidate: Sendable, Identifiable, Equatable {
    public var id: String { path }
    public let path: String; public let ruleID: String; public let category: CleanRule.Category
    public let tier: CleanRule.Tier; public let displayName: String; public let reason: String
    public let measurement: Measurement?   // nil = size unknown (unticked)
    public let requiresAdmin: Bool
    public let owner: String?              // bundle id re-probed before delete
}
public enum SkipReason: Sendable, Equatable { case appRunning(String), ownerUnknown, recent, protected(Refusal), noAccess, neverClean, macOSSystemCache, installedCheckFailed, containsGit, gitTracked, projectInUse, locallyPatched, sameOSInstaller, categoryOff }
public struct SkippedItem: Sendable, Equatable { public let path: String; public let reason: SkipReason }
public struct CleanReport: Sendable { public var candidates: [CleanCandidate]; public var skipped: [SkippedItem] }
public struct ProjectArtifact: Sendable, Equatable { public let path: String; public let project: String; public let projectRoot: String }   // defined here; Task 6 uses it
public protocol CleanProbes: Sendable {
    var now: Date { get }
    func isRunning(bundleID: String) -> Bool?          // nil = couldn't tell
    func isOpen(path: String) -> Bool?
    func isProcessRunning(name: String) -> Bool?       // Gradle daemon check
    func bundleID(appSupportFolder: String) -> String?
    func installedBundleIDs() -> Set<String>?          // Task 5
    func projectArtifacts(roots: [String]) -> [ProjectArtifact]   // Task 6
    func workingDirectories() -> [String]?             // process cwds; nil = couldn't tell
}
public struct CleanEngine {
    public init(rules: [CleanRule], home: String, environment: ProtectionEnvironment,
                probes: any CleanProbes, disabled: Set<CleanRule.Category> = [], projectRoots: [String] = [],
                budget: Duration = .seconds(5))
    public func run(progress: @Sendable (String) -> Void = { _ in }) async -> CleanReport
    public static func expand(_ pattern: String, home: String) -> [String]   // glob over the real filesystem, no symlink following
    public func rule(matching path: String) -> CleanRule?                    // first rule in catalog order whose pattern+unit covers path
    public static func rule(matching path: String, in rules: [CleanRule], home: String) -> CleanRule?   // string-only, used by the root helper
}
public enum CleanCatalog { public static let rules: [CleanRule] }   // in rule order (§6.2a)
```

- Engine pipeline per rule, with rules in catalog order and the first rule to claim a path winning:
  1. Expand the pattern and apply the unit.
  2. Skip paths already claimed.
  3. Apply `exclude` and `fileFilter`.
  4. Protection in `.smartClean`. Refused paths go to Skipped as `.protected` (`.neverClean` gets its own reason).
  5. Measure with the shared `MeasureContext` and a 5 s deadline. A timeout gives a candidate with `measurement: nil`; `.unreadable` goes to Skipped as `.noAccess`, or stays a size-unknown candidate if `requiresAdmin`.
  6. Age tier from `measurement.newest`.
  7. Owner probe: true → `.appRunning`, nil → `.ownerUnknown`. `.containerBundleID` and `requireNotOpen` also call `isOpen(path)`, which is how open SQLite files in containers are caught. `.processName` uses `isProcessRunning`.
  8. Apply `Special` (`.keepNewest(n)` drops the n newest; other specials are Tasks 5 and 6, and until then they offer nothing).
- Children of `~/Library/Caches` whose names aren't bundle ids: the catalog uses a second rule with a ≥ 7-day tier. A bundle id is `^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+){2,}$`.
- Apple children not in the allowlist go to Skipped as `.macOSSystemCache` rather than `.protected(.appleSystem)`.
- Catalog: every row of §6.2 and §6.2a, in §6.2a's rule order, with the spec's tiers, ages and owners verbatim.
  - The user's Darwin cache folder pattern is filled in from `confstr(_CS_DARWIN_USER_CACHE_DIR)` when `rules` is built.
  - Info rows: `.folder`, tier `.info`, `ageTiers: [(0, .info)]`.

- [ ] **Step 1: Tests**

```swift
// CleanEngineTests — fake home under TempDir, FakeProbes(now:, running:, open:)
@Test func ageTiersPickSafeReviewOrRecent()     // rule [(14,.safe),(0,.review)]: 20 d → .safe; 3 d → .review; rule [(7,.safe)] at 2 d → Skipped .recent
@Test func firstMatchingRuleWins()              // specific rule claims ~/Library/Caches/Yarn; generic sweep doesn't list it again
@Test func runningOwnerSkipped()                // owner com.example.app running → Skipped .appRunning("com.example.app")
@Test func unknownOwnerSkipped()                // probe returns nil → Skipped .ownerUnknown
@Test func protectedChildSkipped()              // never-clean entry → Skipped .neverClean, not a candidate
@Test func overBudgetIsSizeUnknown()            // budget: .zero → candidate with measurement == nil
@Test func keepNewestKeepsTwo()                 // 4 version folders → 2 oldest offered
@Test func excludeAndFileFilterApply()          // *.incomplete never offered; fileFilter ["*.log"] skips dirs and other names
@Test func disabledCategoryOffersNothing()
@Test func symlinkedRootExpandsNothingOutside() // fake ~/Library/Caches → link to elsewhere: no candidate path outside home
// CleanCatalogTests — strings only, no filesystem
@Test func catalogMatchesSpecRows()             // rule(matching:) for ~/Library/Caches/com.x.y → appCaches .safe 3 d; ~/Library/Developer/Xcode/DerivedData/P-abc → developer derivedData; /Library/Logs/x → systemLogs requiresAdmin; ~/.Trash/x → trash
@Test func leftoversComeBeforeGenericSweeps()   // index(removedApps rules) < index(generic appCaches/logs rules)
@Test func everySystemRowRequiresAdminExceptDarwinCache()
@Test func neverOfferedSystemPathsHaveNoRule()  // /Library/Updates/x, /private/var/db/uuidtext/x, /private/var/vm/x, /Library/LaunchDaemons/com.apple.x.plist → rule(matching:) == nil
```

- [ ] **Step 2:** Run T. The new tests fail.
- [ ] **Step 3:** Implement the types, the engine and the catalog.
- [ ] **Step 4:** Run T. Everything passes.
- [ ] **Step 5:** Commit: `feat: add smart clean catalog and engine`.

---

### Task 5: Live probes, leftovers of removed apps, and system specials

**Files:**
- Create:
  - `Sources/MacleanCore/ProcessProbes.swift` (libproc: open files, process cwds, process names)
  - `Sources/MacleanCore/InstalledApps.swift`
  - `Sources/Maclean/LiveCleanProbes.swift` (NSWorkspace-backed `CleanProbes`)
- Modify: `Sources/MacleanCore/CleanEngine.swift` (the `.removedAppLeftover`, `.launchdOrphan`, `.macOSInstaller`, `.downloadsInstaller` and `.derivedData` specials)
- Test: `Tests/MacleanCoreTests/CleanSpecialsTests.swift`, `Tests/MacleanCoreTests/ProcessProbesTests.swift`

**Interfaces:**
- Consumes: Task 4 `CleanProbes`, `Special`, `SkipReason`.
- Produces:
  - `ProcessProbes`:
    - `static func pathsOpen(under path: String) -> Bool?`, which scans every pid with `proc_pidinfo(PROC_PIDLISTFDS)` and `PROC_PIDFDVNODEPATHINFO`. Nil on failure.
    - `static func workingDirectories() -> [String]?`
    - `static func processNames() -> [String]?`
  - `InstalledApps.bundleIDs(searchRoots: [String], extra: Set<String>) -> Set<String>?`:
    - reads `.app` bundles to depth 3 under `/Applications`, `/System/Applications`, `~/Applications`, `/opt/homebrew/Caskroom`, `/usr/local/Caskroom` and `~/Applications/Setapp`;
    - `extra` covers running apps, LaunchServices ids and user LaunchAgent labels, which the live probe supplies;
    - returns nil if `/Applications` can't be read.
  - `LiveCleanProbes: CleanProbes`:
    - `isRunning` is an exact match or prefix match against `NSWorkspace.shared.runningApplications` bundle ids;
    - `bundleID(appSupportFolder:)` uses `NSWorkspace.urlForApplication(withBundleIdentifier:)` and app-name lookup through `LSCopyApplicationURLsForBundleIdentifier`.
  - Specials:
    - **`.removedAppLeftover`:** a candidate only if its id is not in `installedBundleIDs()`, it isn't protected, it matches none of `["1password", "keychain", "bitwarden", "ssh", "gpg", "lastpass", "dashlane", "keepass"]`, and it is ≥ 30 days old. If `installedBundleIDs()` is nil, the whole category goes to Skipped as `.installedCheckFailed`. The display name is the bundle id's last component, capitalised.
    - **`.launchdOrphan`:** the plist's `Program` or `ProgramArguments[0]` is absolute and doesn't exist, or a helper's owner bundle id (from `SMAuthorizedClients` or the embedded Info.plist) isn't installed. The reason names the missing program.
    - **`.macOSInstaller`:** ≥ 14 days old and the bundle's `CFBundleShortVersionString` differs from `ProcessInfo.operatingSystemVersion`. Otherwise Skipped as `.sameOSInstaller`.
    - **`.downloadsInstaller`:** age is taken from the `kMDItemDateAdded` xattr when present, else the birth time. The reason is "Installer image downloaded <n> days ago".
    - **`.derivedData`:** the display name is the project name from `info.plist` `WorkspacePath`.
    - **Darwin metal caches:** skipped if any EDR/MDM vendor folder exists. Use Maclean's own list: `/Library/Application Support/CrowdStrike`, `/Library/Application Support/JAMF`, `/Library/Application Support/Microsoft/Defender`, `/Library/Application Support/SentinelOne`, `/opt/cisco`.

- [ ] **Step 1: Tests**

```swift
@Test func leftoverOfUninstalledAppOffered()      // fake installed {com.a.b}; ~/Library/Caches/com.gone.app 40 d → review candidate "App"
@Test func leftoverOfInstalledAppNotLeftover()       // com.a.b goes to generic cache rule instead
@Test func leftoverWithNeverDeleteWordSkipped()      // com.x.bitwarden-helper → not offered
@Test func installedCheckFailureSkipsCategory()      // installedBundleIDs nil → every leftover Skipped .installedCheckFailed
@Test func launchdOrphanNeedsMissingProgram()        // plist Program=/nonexistent → candidate reason contains "/nonexistent"; Program=/bin/ls → nothing
@Test func installerSameOSVersionSkipped()
@Test func derivedDataShowsProjectName()             // info.plist WorkspacePath=/x/MyApp.xcodeproj → displayName "MyApp"
@Test func pathsOpenSeesOwnOpenFile()                // open a TempDir file in-process → ProcessProbes.pathsOpen(under: dir) == true; closed dir → false
@Test func workingDirectoriesIncludeSelf()           // chdir not needed: result contains FileManager.default.currentDirectoryPath (realpath)
```

- [ ] **Step 2:** Run T. The new tests fail.
- [ ] **Step 3:** Implement. `LiveCleanProbes` isn't unit-tested beyond compiling; the manual checklist covers it.
- [ ] **Step 4:** Run T. Everything passes.
- [ ] **Step 5:** Commit: `feat: add live probes and leftover detection`.

---

### Task 6: Project leftovers (build artifacts)

**Files:**
- Create: `Sources/MacleanCore/ProjectArtifacts.swift`
- Modify: `Sources/MacleanCore/CleanEngine.swift` (the `.projectArtifacts` special)
- Test: `Tests/MacleanCoreTests/ProjectArtifactsTests.swift`

**Interfaces:**
- Produces:
  - `ProjectArtifact` is already defined by Task 4 in `CleanRule.swift`. Use it; don't redefine it.
  - `public enum ProjectArtifacts`:
    - `static func searchRoots(home: String, extra: [String]) -> [String]` covers the §6.5 named folders that exist, plus top-level home folders with a marker within depth 2 (excluding Library, Movies, Music, Pictures, Public, Applications and hidden folders), plus `extra`.
    - `static func find(roots: [String], deadline: ContinuousClock.Instant?) -> [ProjectArtifact]` searches depth 1–6, prunes `.git`, `Library` and `.Trash`, skips dataless files (`SF_DATALESS`), and returns only outermost artifacts.
    - `static func keepReason(_ a: ProjectArtifact, cwds: [String]?) -> SkipReason?` returns, in order: `.containsGit`, `.gitTracked` (via `git -C <root> ls-files -z -- <artifact>` with a 3 s timeout, where a timeout or error means `.gitTracked`), `.projectInUse` (a cwd inside `projectRoot`, or `cwds == nil`), or `.locallyPatched` (a `node_modules` whose `.package-lock.json` is missing or older than any file directly inside it).
- Markers and artifact-name pairings are §6.5 verbatim, including "`target`/`build`/`dist` need the matching marker". `bin`, `obj` and `vendor` are not offered.
- The engine maps artifacts through `ageTiers: [(30, .safe), (7, .review)]`. Younger than 7 days goes to Skipped as `.recent`. Rows group by `project`.

- [ ] **Step 1: Tests** (TempDir projects; init real git repos with `git init` inside TempDir)

```swift
@Test func nodeModulesBesidePackageJsonFound()
@Test func targetNeedsCargoOrPom()                 // target/ beside Cargo.toml found; target/ alone not
@Test func buildNeedsMarker()                      // build/ beside package.json found; build/ in plain folder not
@Test func outermostOnly()                         // node_modules/x/node_modules → only outer
@Test func gitTrackedArtifactKept()                // committed dist/ file → .gitTracked
@Test func artifactWithGitInsideKept()             // .containsGit
@Test func projectInUseKept()                      // cwds contains projectRoot/src → .projectInUse; cwds nil → .projectInUse
@Test func locallyPatchedNodeModulesKept()
@Test func depthLimitSix()                         // marker at depth 7 ignored
@Test func searchRootsDetectMarkerFolders()        // ~/stuff/app/package.json → ~/stuff included; ~/Movies never
```

- [ ] **Step 2:** Run T. The new tests fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run T. Everything passes.
- [ ] **Step 5:** Commit: `feat: find project build leftovers`.

---

### Task 7: Root helper for Smart Clean (delete and measure)

**Files:**
- Modify:
  - `Sources/MacleanCore/AdminDelete.swift`
  - `Sources/maclean-scan/main.swift`
- Create: `Sources/MacleanCore/AdminMeasure.swift`
- Test: `Tests/MacleanCoreTests/AdminDeleteTests.swift`, `Tests/MacleanCoreTests/AdminMeasureTests.swift`

**Interfaces:**
- Consumes: Task 1 `--context`, Task 2 `Measurer`, Task 4 `CleanEngine.rule(matching:)` and `CleanCatalog.rules`.
- Produces:
  - In `AdminDelete.perform(_:with:)`, when the deleter's context is `.smartClean`, two checks run before anything else:
    - The item's path must match a catalog rule with `requiresAdmin`, using `CleanEngine.rule(matching:in:home:)` with `env.home`. Otherwise `.refused(.unsafePath)`.
    - It must still be at least as old as the smallest `days` in the rule's `ageTiers`. The age is measured as root; if it's too new, the result is `.changedSinceScan(size:fileCount:)` with the measured values.
  - `AdminMeasure`:
    - `arguments(pathsFile:sha256:environment:)` gives `smart-measure --env <json> --paths-file <p> --paths-sha256 <hex>`.
    - `parse` uses the same `O_NOFOLLOW`, regular-file and hash checks as the items file. Factor out the shared `readVerifiedFile(path:sha256:)`.
    - `encode` and `decode` work on JSON lines `{path, measurement?, error?}`.
    - Only catalog paths with `requiresAdmin` are measured; anything else gets `error: "not a system cleanup target"`.
  - The helper adds a `smart-measure` mode, which also requires uid 0.

- [ ] **Step 1: Tests**

```swift
@Test func smartCleanPerformRefusesNonCatalogPath()   // TempDir path, context .smartClean → .refused(.unsafePath), file still exists
@Test func collectorPerformUnaffected()               // same path, .collector → deleted (TempDir)
@Test func measureArgumentsRoundTrip() throws
@Test func measureRefusesTamperedPathsFile() throws   // rewritten file → parse throws
@Test func measureLinesRoundTrip()
@Test func measureRejectsNonSystemPath()              // AdminMeasure.measureAll(["/Users/me/x"]) → error line
```

- [ ] **Step 2:** Run T. The new tests fail.
- [ ] **Step 3:** Implement. To test the age re-check without root, expose `AdminDelete.smartCleanVerdict(for path: String, rules: [CleanRule], now: Date) -> DeleteOutcome?` and test it with a fake rule over a TempDir path.
- [ ] **Step 4:** Run T. Everything passes.
- [ ] **Step 5:** Commit: `feat: root helper checks smart clean rules`.

---

### Task 8: SmartCleanController (check, selection, clean)

**Files:**
- Create: `Sources/Maclean/SmartCleanController.swift`
- Modify:
  - `Sources/Maclean/SessionRegistry.swift` (`markRemoved(_ requests: [DeleteRequest])`)
  - `Sources/Maclean/MacleanApp.swift` (owns the controller and starts the launch check)
- Test: `Tests/MacleanAppTests/SmartCleanControllerTests.swift`

**Interfaces:**
- Consumes:
  - `CleanEngine` and `CleanCatalog` (Task 4);
  - `LiveCleanProbes` (Task 5);
  - `DeleteBatch` (Task 1);
  - `AdminMeasure` (Task 7);
  - `AdminRunning`.
- Produces: `@MainActor @Observable final class SmartCleanController`

```swift
enum Phase: Equatable { case idle, checking, ready, nothingFound, confirming, cleaning(done: Int, total: Int), summary(DeleteReport) }
private(set) var phase: Phase
private(set) var report: CleanReport?
var selected: Set<String>                 // paths; defaults: tier == .safe && measurement != nil
var selectedSize: Int64 { get }; var foundSize: Int64 { get }
var needsAdmin: Bool { get }              // any selected requiresAdmin
init(engine: @escaping () -> CleanEngine, probes: any CleanProbes,
     makeDeleter: @escaping (DeleteMode, ProtectionContext) -> any DeleterProtocol, admin: any AdminRunning,
     defaults: UserDefaults = .standard, scanning: @escaping (Int32) -> Bool)   // device → a scan of that volume is running
func checkAtLaunchIfEnabled()             // reads smartClean.checkAtLaunch
func check()                              // utility QoS; cancels a running check first
func neverClean(_ path: String)           // appends to smartClean.neverClean, re-runs check
func measureWithAdmin() async             // one prompt; fills measurements for size-unknown requiresAdmin rows
func clean() async                        // after the view's confirmation alert
func dismissSummary()
```

- **The check:**
  - It runs the engine off the main actor and publishes the `CleanReport`.
  - It pauses between targets while `scanning(device)` is true, polling every 0.5 s.
  - A cancelled check (window closed or app quitting) publishes nothing.
- **Clean:**
  - Builds `DeleteBatch.Item`s from the selected candidates:
    - `tolerance: .cache` only when the tier is `.safe` and the category is `appCaches`, `browsers`, `logs`, `systemLogs` or `systemCaches`; `.strict` for everything else;
    - `mode: .permanent` for the Trash category;
    - context `.smartClean`.
  - `beforeEach` re-runs `probes.isRunning(owner)` and returns "<App> is open." when it's true or nil.
  - After the run, `registry.markRemoved` the deleted requests: in every session, `tree.node(atPath:)`, then an inode and device match, then `markRemoved`.
  - Then it re-checks in the background so the card updates.

- [ ] **Step 1: Tests** (fake engine output, fake deleter, fake admin, FakeProbes)

```swift
@Test func defaultSelectionIsSafeWithKnownSize()      // safe+measured selected; review, info, size-unknown not
@Test func ownerOpenAtCleanSkipsItem()                // probes flip running before clean → report.failed[path] == "Example is open."
@Test func safeCacheUsesCacheTolerance()              // request.tolerance == .cache for appCaches; .strict for removedApps
@Test func trashCategoryAlwaysPermanent()             // trash mode on → trash item deleted with .permanent
@Test func cancelledPromptSkipsOnlySystemItems()      // admin throws .cancelled → system item failed adminNotGiven; user item deleted
@Test func deletedPathsMarkedRemovedInSessions()      // session tree containing path → view.removed contains node after clean
@Test func checkWaitsWhileVolumeScanning()            // scanning true → stays .checking; set false → .ready
@Test func launchCheckRespectsSetting()               // smartClean.checkAtLaunch false → phase stays .idle
@Test func neverCleanPersistsAndRechecks()
```

- [ ] **Step 2:** Run T. The new tests fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run T. Everything passes.
- [ ] **Step 5:** Commit: `feat: add smart clean controller`.

---

### Task 9: Smart Clean UI (card, review sheet, Settings, menu)

**Files:**
- Create:
  - `Sources/Maclean/SmartCleanCard.swift`
  - `Sources/Maclean/SmartCleanReviewView.swift`
  - `Sources/Maclean/SmartCleanSettings.swift`
- Modify:
  - `Sources/Maclean/StartView.swift` (the card below the disk list)
  - `Sources/Maclean/SettingsView.swift` (a "Smart Clean" tab)
  - `Sources/Maclean/AppCommands.swift` (Action › Check for Cleanable Items, ⇧⌘K)
  - `Sources/Maclean/DeleteSummaryView.swift` (accepts a `DeleteReport` plus title copy, so both flows share it)
- Test: `Tests/MacleanAppTests/SmartCleanUITests.swift`

**Interfaces:**
- Consumes: Task 8 `SmartCleanController`.
- Produces:
  - **Card (§5.2):**
    - An icon, the size line, and the top 3 categories by size.
    - A **Review…** button.
    - A spinner while checking.
    - "Nothing to clean right now", which fades after 3 s.
    - Hidden while a result fills the window in one-window mode.
  - **Review sheet:**
    - A header with selected and found sizes, a **Check again** button, and a red **Clean** button that is disabled when nothing is selected.
    - Category sections: a tri-state checkbox, name, total and disclosure.
    - Rows: checkbox, icon, name, middle-truncated path, size or "size unknown", "last used <relative>", and the reason.
    - Info rows: **Show in Finder** and **Scan this folder**, which opens it in a scan window.
    - A row context menu: Show in Finder, Open in Terminal, Quick Look, Never clean this.
    - A system group with **Measure with administrator rights** when any row is size-unknown and needs admin.
    - A collapsed "Skipped (n)" section, with each reason in plain words. "needs Full Disk Access" links to `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.
    - Clean shows the confirmation alert (copy as in Global Constraints), then progress with Stop, then the shared summary sheet.
  - **Settings › Smart Clean:**
    - the launch-check toggle;
    - one toggle per category;
    - the never-clean list with remove buttons;
    - project search roots with Add… and remove.
  - **Pure helpers, so they can be tested:**
    - `SmartCleanCopy.cardLine(_ report: CleanReport) -> String`
    - `SmartCleanCopy.skipReason(_ r: SkipReason) -> String`
    - `SmartCleanCopy.alert(count:size:mode:needsAdmin:) -> (title: String, message: String)`
    - `CategoryState.tri(_ paths: [String], selected: Set<String>) -> NSControl.StateValue`

- [ ] **Step 1: Tests**

```swift
@Test func cardLineUsesTotalAndTopThree()        // "18.6 GB can be cleaned" and 3 category names
@Test func alertCopyPermanentAndAdmin()          // title "Delete 214 items (12.1 GB)?"; message contains "deleted permanently" and "administrator password"
@Test func alertCopyTrash()                      // "moved to the Trash"
@Test func everySkipReasonHasCopy()              // no reason maps to an empty string
@Test func triStateMixed()                       // 1 of 2 selected → .mixed
```

- [ ] **Step 2:** Run T. The new tests fail.
- [ ] **Step 3:** Implement the views. Build the app with `scripts/build-app.sh`.
- [ ] **Step 4:** Run T. Everything passes, and the build succeeds.
- [ ] **Step 5:** Commit: `feat: add smart clean card, review and settings`.

---

### Task 10: Docs and outcome

**Files:**
- Modify:
  - `README.md` (a Smart Clean section: what it checks, tiers, never-clean, system items and the password)
  - `docs/manual-checklist.md` (a "Smart Clean" section)
  - this plan (an "Outcome and follow-ups" section)

- [ ] **Step 1:** Add checklist items, all inside `~/maclean-scratch` or as reads:
  - The launch card appears and finishes within about 10 s.
  - Review shows Safe items ticked, Review items unticked, and Info items with no checkbox.
  - With an app open, its cache shows as Skipped "app running".
  - Never clean this hides the row and lists it in Settings.
  - Measure with administrator rights asks for the password once.
  - Clean on a scratch project's `node_modules`, created at least 30 days old with `touch -t`, removes it.
  - A cancelled password prompt leaves system items listed as "administrator password not given".
  - ⇧⌘K re-runs the check.
  - Turning the setting off stops the launch check.
- [ ] **Step 2:** Run T and `scripts/build-app.sh`, and record the counts in the outcome.
- [ ] **Step 3:** Commit: `docs: smart clean readme, checklist, plan outcome`.

---

## Outcome and follow-ups (recorded after execution)

Built on branch `plan-03b-smart-clean`, 20 commits from main 44023c3 (1 preflight docs commit, 9 feature commits, 9 fix commits, and this docs commit); 363 tests (44 MacleanKit + 244 MacleanCore + 75 MacleanApp), all passing, and `scripts/build-app.sh` builds and signs the bundle. Shipped: `DeleteBatch` extracted from the collector with a `ProtectionContext` threaded through `Deleter` and `AdminDelete` (`--context`), the timestamp-aware `Measurer`, the `.smartClean` protection context with its own dangerous-path corpus, the catalog of rules and `CleanEngine`, live probes (open files, running owners, installed apps), leftovers of removed apps, project build artifacts with a hardened Git probe, the root-side re-checks (`AdminMeasure`, launchd orphan re-check, bounded no-follow plist reads), `SmartCleanController`, `TreeView.markDeleted`, the start-screen card, the review sheet (tiers, Skipped, Never clean this, Measure with administrator rights), Settings › Smart Clean, and Action › Check for Cleanable Items (⇧⌘K). The README and manual checklist cover Smart Clean.

**Rulings worth remembering** (the full list is R1–R31 in the SDD ledger)
- **Unknown means keep:** a failed probe goes to Skipped; a size-unknown item is capped at Review and never ticked.
- **Protection:** smartClean refuses everything under `/private` outside the §6.2a allowlist, under `/usr` and under `/Volumes` unless inside home (R1, R2, R8, R10, R11); Apple names are allowed only where the spec lists them.
- **ctime:** `Measurement.newest` is max(mtime, ctime), and tests can't backdate ctime, so tests inject `now` instead (R7).
- **Root trust:** root re-runs the age check (smallest tier) and the launchd-orphan check before measuring or deleting system items, and uses its own installed-apps set that ignores the app-supplied home (R4, R22, R23).
- **Tolerance:** Safe-tier cache and log rows tolerate content changes between check and clean; everything else is strict (R5). The Trash category is always permanent.
- **Git probe:** `git ls-files` runs with fsmonitor, hooks and global config disabled, because the repository is untrusted.
- **Admin:** system rows reuse the collector's single-prompt admin batch; measuring with administrator rights is a separate single prompt.
- **⇧⌘K** brings the main window back to the start screen, where the card is the result surface (R26).
- **Final review (R27–R30):** system items skip the user-level attempt and go straight to the admin batch, so a partial delete can't trip root's age check (R27); the launch check raises no system dialogs: no TCC-protected rule is read without Full Disk Access, Desktop, Documents and Downloads are never auto-searched for projects, and git runs only when a real git is installed (R28, R29); in Trash mode the alert says system items will be skipped instead of promising a password prompt (R30).

**Deferred minors**
- Interface: collector items leave at the end of a run, not per item; default contexts remain only on `Deleter.init` and `ProtectionRules.refusal` (`AdminDelete.resolvedRefusal` takes the deleter's context); `publish()` is an internal test seam; `isChecking`, `requestClean`, `cancelClean` and `stop` have thin test coverage.
- Measurer and engine: the clone test passes silently on non-APFS; recursion holds one fd per depth; a vanished-after-timeout item reports `.noAccess`; size-unknown age uses top-level times only; installed-app probing runs even with categories off.
- Protection: any path ending in a `Safari` component is refused; personal-data names match at any depth.
- Catalog and probes: Trash offers `.DS_Store` as separate rows; Gradle's owner is any `java` process and isn't re-checked at delete time; the macOS installer version check is best effort (R16); EDR skip says "protected" (R17); App Support leftovers match only by bundle-id name.
- Projects: the `locallyPatched` doc says oldest record but the code uses the newest; `node_modules/.cache` can give false positives; measuring happens before the keep checks.
- Root helper: a user-root walk error drops that root's ids; errno isn't reset per `readdir`; Caskroom is walked with system trust; a symlinked user Applications root is followed; no deadline on the root age measure; root doesn't re-check open files, running owners or installer versions.
- UI: the card's faded state is view-local; the review regroups rows on every body pass; the Smart Clean summary has no Keep/Delete Anyway for changed items; the card sits on the start screen only, so a one-window result view hides it.

**Manual checks still pending with the owner (before merge)**
- GUI pass: the UI was never launched. Run the Smart Clean section of `docs/manual-checklist.md` in light and dark mode (card, review, Skipped, Never clean this, Settings tab, ⇧⌘K, Quick Look from the sheet).
- The admin password step: Measure with administrator rights, and a real clean of system items through the osascript prompt, plus a cancelled prompt.

**Before the next plan**
- The helper-replacement caveat from Plan 3a still applies to the root batch (a signed `SMAppService` helper is the fix).
- Accepted residual (R31): the request self-declares `--context`, so a tampered request can choose the collector root path instead of Smart Clean's. The argv SHA pin is the trust boundary; the Smart Clean root checks (catalog admin rule, root age re-check) are defence in depth.
