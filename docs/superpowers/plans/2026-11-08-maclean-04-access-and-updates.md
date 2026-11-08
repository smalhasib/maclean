# Maclean Plan 4: Access and Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Maclean guides the user to Full Disk Access on every launch until it's granted. It asks for the administrator password with a dialog that names Maclean, to read restricted folders and measure Smart Clean system items. It updates itself from signed GitHub releases, and its release builds keep a stable signature so permissions survive updates.

**Architecture:**
- **One admin dialog:** `AdminRunner` runs the root helper through in-process `NSAppleScript`, so the system dialog names Maclean. It accepts a batch of helper invocations, so one dialog can serve several jobs.
- **One coordinator:** a `PromptCoordinator` orders the launch-time prompts: the Full Disk Access sheet, then the update sheet, then an administrator dialog.
- **Admin reads:** a new read-only helper mode scans restricted folders as root into tree archives, which `ScanSession` grafts into its `FileTree`.
- **Updates:** they use the GitHub Releases API, Ed25519 signatures (CryptoKit) and an in-place bundle swap. Homebrew installs are left to `brew`.

**Tech Stack:**
- Swift 6.4, SwiftPM with Command Line Tools only.
- SwiftUI and AppKit, Swift Testing.
- NSAppleScript, CryptoKit, URLSession.
- `ditto`, `codesign`, `security`, `openssl` in scripts.

**Spec:** `docs/superpowers/specs/2026-11-08-maclean-access-and-updates-design.md`. This spec is binding, and §6a holds the decisions that override the earlier sections.

## Global Constraints

- **Toolchain:** macOS 14+, Swift 6 language mode, **no third-party dependencies**.
  - Tests run with `swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing` (**T**).
  - `@State` doesn't compile with Command Line Tools; use `State(initialValue:)`.
- **Safety:** no test deletes real user files, runs the real updater against `/Applications`, or calls the real `NSAppleScript` admin dialog. Use fakes, TempDir, and a test Ed25519 key pair.
- **Root helper:** it keeps every existing safety property.
  - The `read-restricted` mode is **read-only**, requires uid 0, and reads its path list from a 0600 file whose SHA-256 is in argv (`readVerifiedFile`).
  - The `install-update` mode (Task 6b) writes only the verified Maclean bundle over an existing Maclean bundle, under the checks in spec §6a.2.
- **Copy:**
  - **FDA sheet:** "Give Maclean Full Disk Access"; the steps "Open System Settings › Privacy & Security › Full Disk Access", "Turn on Maclean" and "Maclean relaunches when you come back"; the button **Open System Settings**; the link "Continue without Full Disk Access".
  - **Start-screen notice:** "Scans will miss protected folders — Grant Access…".
  - **After the grant:** "Full Disk Access is on. Relaunch Maclean to use it." with **Relaunch**.
  - **Admin reasons:** "Maclean needs to read N folders that only an administrator can open." and "Maclean needs to measure N system items for Smart Clean.". Joined with a space when one dialog serves both.
  - **Scan result:** "N folders couldn't be read — Read with administrator rights" and "N folders still need Full Disk Access — Grant Access…".
  - **Update sheet:**
    - "Maclean X is available", "You have Y", "What's new";
    - the box "Check for updates automatically";
    - the buttons **Skip This Version**, **Later** and **Install and Relaunch** (the default), on one line;
    - for Homebrew installs, `brew upgrade --cask maclean` with **Copy Command**;
    - when Maclean can't replace itself, **Install and Relaunch** asks for the administrator password ("Maclean needs your password to update itself."); **Download** is the fallback after a cancel.
- **UserDefaults keys:**
  - `access.askForAdminReads` (Bool, default `true`)
  - `update.automatic` (Bool, default `true`)
  - `update.lastCheck` (Date)
  - `update.skippedVersion` (String)
- **Updates:**
  - API: `https://api.github.com/repos/smalhasib/maclean/releases/latest`.
  - Assets: `Maclean-<version>.zip` and `Maclean-<version>.zip.sig`, where the `.sig` is the base64 of the raw 64-byte Ed25519 signature over the zip bytes.
  - Bundle id: `org.maclean.Maclean`.
  - Automatic checks run at most once per 24 h.
- **Homebrew install** means both of these hold: `/opt/homebrew/Caskroom/maclean` or `/usr/local/Caskroom/maclean` exists, and the running bundle path is `/Applications/Maclean.app`.
- **Signing:** the release signing identity is the self-signed certificate "Maclean Release" in the owner's login Keychain. Development builds stay ad hoc.
- **Commits:** Conventional Commits with no AI attribution trailer. Never push.

## Review Focus

1. **Full Disk Access granted while the sheet is open, or revoked between launches.** On re-activation the sheet switches to the Relaunch state. When access is revoked, the sheet appears on the next launch. Test in Task 2.
2. **The admin dialog cancelled.** Restricted folders stay restricted with the "Read with administrator rights" button. Smart Clean rows stay "size unknown". There is no second automatic prompt for that scan or check. Tests in Task 4.
3. **A scan read and a Smart Clean measure pending at the same time.** One dialog, with the reasons joined, and both results applied. Test in Task 4.
4. **A tampered or mismatched update, including through the password route.** A wrong signature, a wrong bundle id, a version that differs from the release, or a truncated download: each is refused with a message, and the installed app is untouched. Tests in Task 6.
5. **Path checks.** A restricted path outside the scan root, an output directory that is a symlink or not owned by the uid, or a path list that doesn't match its hash: the helper refuses each one. Tests in Task 3.

---

### Task 1: AdminRunner in-process, with prompt and batches

**Files:**
- Modify:
  - `Sources/Maclean/AdminRunner.swift`
  - every call site of `AdminRunning.run` (the DeleteBatch and SmartCleanController admin calls)
  - the test fakes in `Tests/MacleanAppTests` that conform to `AdminRunning`
- Test: `Tests/MacleanAppTests/AdminRunnerTests.swift`

**Interfaces:**
- Produces:
  - `protocol AdminRunning: Sendable { func run(_ invocations: [[String]], prompt: String) async throws -> [String] }`. It runs the bundled `maclean-scan` once per invocation, all inside **one** `do shell script … with administrator privileges with prompt <prompt>`, and returns each invocation's stdout in order.
  - A convenience extension `func run(_ arguments: [String], prompt: String) async throws -> String`.
  - `AdminRunnerError` is unchanged (`.cancelled` when AppleScript error -128).
  - `static func script(helper: String, invocations: [[String]], prompt: String) -> (source: String, separator: String)`. A pure function that builds AppleScript source in which:
    - every argument is wrapped with `quoted form of` from a list literal of AppleScript string literals, escaping `\` and `"`;
    - invocations are joined by `; printf '%s\n' <separator>; `;
    - the separator is a random UUID-based marker chosen per call.
  - `AdminRunner` executes the source with `NSAppleScript` off the main thread (a detached task on a serial queue), maps error number -128 to `.cancelled`, and splits stdout on the separator line. Keep "no timeout".
- Delete callers pass the existing delete reason, "Maclean needs to delete items that only an administrator can remove.". Smart Clean's measure passes the measure reason from Global Constraints.

- [ ] **Step 1: Tests**

```swift
@Test func scriptQuotesEveryArgument()      // invocations [["--delete","a b","x\"y\\z","$(rm -rf ~)"]] → source contains no unescaped arg text outside string literals; every arg appears inside quoted form of
@Test func scriptJoinsInvocationsWithSeparator()   // 2 invocations → source contains separator once between them
@Test func splitOutputsBySeparator()        // AdminRunner.split("out1\n<sep>\nout2", separator: "<sep>") == ["out1\n", "out2"]
@Test func promptIsEscaped()                // prompt containing quotes and backslash stays one string literal
```

- [ ] **Step 2:** Run T. The new tests fail.
- [ ] **Step 3:** Implement the code and update the call sites and fakes. The existing tests must pass unchanged in behaviour.
- [ ] **Step 4:** Run T and `scripts/build-app.sh`. Both pass.
- [ ] **Step 5:** Commit: `feat: run admin helper in-process with prompt`.

---

### Task 2: Full Disk Access sheet, relaunch, and prompt coordinator

**Files:**
- Create:
  - `Sources/Maclean/FullDiskAccess.swift`
  - `Sources/Maclean/PromptCoordinator.swift`
  - `Sources/Maclean/FullDiskAccessSheet.swift`
  - `Sources/Maclean/Relauncher.swift`
- Modify:
  - `Sources/Maclean/LiveCleanProbes.swift` (uses `FullDiskAccess.isGranted`)
  - `Sources/Maclean/StartView.swift` (the sheet and the notice)
  - `Sources/Maclean/MacleanApp.swift` (owns the coordinator; re-probes on `applicationDidBecomeActive`)
- Test: `Tests/MacleanAppTests/PromptCoordinatorTests.swift`

**Interfaces:**
- Produces:
  - `enum FullDiskAccess { static func isGranted(home: String = NSHomeDirectory()) -> Bool }`. It moves the existing TCC.db probe here, unchanged.
  - `enum Relauncher { static func relaunch(bundleURL: URL = Bundle.main.bundleURL) }`. It spawns a detached `/bin/sh -c 'sleep 1; open -n "$0"' <path>`, then calls `NSApp.terminate(nil)`.
  - `@MainActor @Observable final class PromptCoordinator`:
    - `enum Sheet: Equatable { case fullDiskAccess(granted: Bool), update }`.
    - `private(set) var sheet: Sheet?` and `private(set) var showsAccessNotice: Bool`.
    - `init(hasAccess: @escaping () -> Bool)`.
    - `func launch()`: shows `.fullDiskAccess(granted: false)` when there's no access.
    - `func continueWithoutAccess()`: closes the sheet and sets the notice.
    - `func reopenAccessSheet()`.
    - `func becameActive()`: re-probes; if access is now granted while the sheet or notice is showing, it shows `.fullDiskAccess(granted: true)`.
    - `func requestUpdateSheet()`: queued until the sheet slot is free.
    - `func dismissSheet()`.
    - `func admin<T>(_ reason: String, _ job: @escaping @MainActor () async -> T) async -> T`. Admin jobs wait until `sheet == nil`, then run one at a time, so jobs never overlap.
    - The batching of a scan read with a measure lives in Task 4 (`AdminBatcher`).

- [ ] **Step 1: Tests**

```swift
@Test func launchWithoutAccessShowsSheet()        // hasAccess false → sheet == .fullDiskAccess(granted: false)
@Test func launchWithAccessShowsNothing()
@Test func continueShowsNotice()                  // continueWithoutAccess → sheet nil, showsAccessNotice
@Test func grantNoticedOnActivation()             // flip hasAccess true, becameActive → .fullDiskAccess(granted: true)
@Test func updateSheetWaitsForAccessSheet()       // requestUpdateSheet while access sheet up → still access; dismiss → .update
@Test func adminJobWaitsForSheetsAndRunsSerially()// job started while sheet up doesn't run until dismiss; two jobs never overlap
```

- [ ] **Step 2:** Run T. The new tests fail.
- [ ] **Step 3:** Implement the code.
  - The sheet follows mockup A, using the copy from Global Constraints.
  - **Open System Settings** opens `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.
  - The granted state shows **Relaunch**, which calls `Relauncher.relaunch()`.
  - The start-screen notice row reopens the sheet.
  - The launch Smart Clean check still starts right away.
- [ ] **Step 4:** Run T and `scripts/build-app.sh`. Both pass.
- [ ] **Step 5:** Commit: `feat: full disk access sheet and prompt coordinator`.

---

### Task 3: Root helper read mode and tree grafting

**Files:**
- Create: `Sources/MacleanCore/AdminRead.swift`
- Modify:
  - `Sources/MacleanCore/FileTree.swift` (adds `grafting`)
  - `Sources/maclean-scan/main.swift` (adds the `read-restricted` mode)
- Test: `Tests/MacleanCoreTests/AdminReadTests.swift`, `Tests/MacleanCoreTests/FileTreeGraftTests.swift`

**Interfaces:**
- Produces:
  - `AdminRead.arguments(root: String, pathsFile: String, sha256: String, outDir: String, uid: uid_t) -> [String]`, which gives `read-restricted --root <root> --paths-file <p> --paths-sha256 <hex> --out-dir <d> --uid <n>`.
  - `AdminRead.parse(_:) throws -> Request`, where `Request` is `{ root, paths, outDir, uid }`, read through the shared `readVerifiedFile`.
  - `AdminRead.writePathsFile(_ paths: [String]) throws -> (url: URL, sha256: String)` and `AdminRead.makeOutDir() throws -> URL`, a fresh 0700 temp directory.
  - `AdminRead.perform(_ request: Request, scan: (String, ScanBoundary) async throws -> FileTree) async -> [Line]`.
    - `Line` is `{ path, file?, error? }`, Codable, with `encode`/`decode` as JSON lines like `AdminMeasure`.
    - It refuses the whole request unless `outDir` is a real directory: `lstat` shows it isn't a symlink, its mode is 0700, and it is owned by `uid`.
    - Each path must be canonical and strictly inside the canonical `root`; otherwise that line gets `error: "outside the scan"`.
    - It scans with `ScanBoundary.forRoot(root)`, writes `outDir/<index>.mtree` with `TreeArchive.write`, then `fchown`s it to `uid` with mode 0600.
  - `FileTree.grafting(_ subtrees: [String: FileTree]) -> FileTree`. It returns a new tree where each `.restricted` node whose path is a key gets that subtree's children:
    - names, sizes, flags, inodes and devices are copied;
    - `.restricted` is cleared on the node;
    - ancestor sizes are recomputed;
    - keys that are missing or not restricted are ignored.
  - The CLI mode `read-restricted` requires uid 0 and prints one JSON line per path.

- [ ] **Step 1: Tests**

```swift
// FileTreeGraftTests (build small trees with FileTreeBuilder)
@Test func graftFillsRestrictedNode()          // root/a(restricted, 0) + subtree a{x:100,y:50} → a.size 150, root grows by 150, a not restricted, children x,y
@Test func graftIgnoresUnknownAndUnrestricted()
@Test func graftKeepsOtherNodesIdentical()     // untouched sibling paths, sizes, inodes unchanged
// AdminReadTests (TempDir; scan closure = Scanner.scan(path:boundary:))
@Test func argumentsRoundTrip() throws
@Test func refusesTamperedPathsFile() throws
@Test func refusesOutDirSymlinkOrWrongOwnerOrMode() async  // symlink → all lines error; 0755 → error; uid mismatch (pass uid+1) → error
@Test func refusesPathOutsideRoot() async      // root=T/r, path T/other → error "outside the scan"; T/r/../other → error
@Test func writesArchivePerPath() async        // two dirs under root → two .mtree files readable by TreeArchive.read with expected sizes
```

- [ ] **Step 2:** Run T. The new tests fail.
- [ ] **Step 3:** Implement the code. Run the uid check with `getuid()` as the expected owner in tests, and `fchown` only when running as root.
- [ ] **Step 4:** Run T and `swift build`. Both pass.
- [ ] **Step 5:** Commit: `feat: root read mode for restricted folders, tree graft`.

---

### Task 4: Ask for the password during scans and Smart Clean

**Files:**
- Create: `Sources/Maclean/AdminBatcher.swift`
- Modify:
  - `Sources/Maclean/ScanSession.swift`
  - `Sources/Maclean/ResultView.swift`, or the view that shows the restricted notice
  - `Sources/Maclean/SmartCleanController.swift`
  - `Sources/Maclean/SettingsView.swift` (the `access.askForAdminReads` toggle "Ask for the administrator password to read restricted folders")
  - `Sources/Maclean/MacleanApp.swift` (wiring)
- Test: `Tests/MacleanAppTests/AdminBatcherTests.swift`, `Tests/MacleanAppTests/AdminReadSessionTests.swift`

**Interfaces:**
- Consumes: Task 1 `AdminRunning.run(_:prompt:)`, Task 2 `PromptCoordinator.admin`, and Task 3 `AdminRead` and `FileTree.grafting`.
- Produces:
  - `@MainActor final class AdminBatcher`, with `init(runner: any AdminRunning, coordinator: PromptCoordinator)`.
    - `func submit(_ arguments: [String], reason: String) async throws -> String`.
    - Submissions arriving within the same main-actor turn, before the coordinator grants the slot, go out as **one** `run(invocations, prompt: reasons.joined(separator: " "))`, and each caller gets its own output.
    - A cancel throws `.cancelled` to every caller in that batch.
  - `ScanSession` gains:
    - `var restrictedCount: Int`;
    - `var stillNeedsAccessCount: Int?`;
    - `func readRestricted(using batcher: AdminBatcher) async`, which writes the paths file and out dir, submits, reads the archives, applies `grafting`, carries the overlay over, and sets `stillNeedsAccessCount` to the restricted nodes left.
  - After a scan finishes, the registry calls `readRestricted` once when `access.askForAdminReads` is on and `restrictedCount > 0`. A cancel or failure leaves the tree unchanged, and the result view offers "Read with administrator rights".
  - `SmartCleanController.measureWithAdmin` goes through the batcher. After `publish`, it runs once automatically when `access.askForAdminReads` is on and admin items have unknown sizes. There's no automatic retry after a cancel.

- [ ] **Step 1: Tests**

```swift
@Test func batcherMergesConcurrentSubmissions() async  // two submits same turn → fake runner called once with 2 invocations, prompt = both reasons joined; each gets own output
@Test func batcherCancelReachesAllCallers() async
@Test func scanAsksOnceAndGrafts() async               // fake runner returning lines pointing at TreeArchive files built in TempDir → session tree updated, restrictedCount drops, prompt contains "read 2 folders"
@Test func scanCancelLeavesTreeAndNoReask() async      // .cancelled → tree identical, no second automatic call
@Test func settingOffNeverAsks() async
@Test func stillNeedsAccessCounted() async             // runner returns error for one path → stillNeedsAccessCount == 1
@Test func smartCleanAutoMeasuresOnceAfterCheck() async// unknown admin item → one runner call with measure reason; cancel → stays size unknown, no retry
@Test func scanReadAndMeasureShareOneDialog() async    // both pending → runner called once
```

- [ ] **Step 2:** Run T. The new tests fail.
- [ ] **Step 3:** Implement the code. Carry collected items over with the existing `carriedOver(to:)` path.
- [ ] **Step 4:** Run T and `scripts/build-app.sh`. Both pass.
- [ ] **Step 5:** Commit: `feat: ask for admin password to read restricted items`.

---

### Task 5: Update core (versions, release info, signatures, install source)

**Files:**
- Create: `Sources/MacleanCore/Update.swift`
- Test: `Tests/MacleanCoreTests/UpdateTests.swift`

**Interfaces:**
- Produces:
  - `public struct SemanticVersion: Comparable, Sendable { init?(_ text: String) }`. It accepts `1.2.3`, a `v1.2.3` prefix, and missing minor or patch parts (`1.2` means `1.2.0`).
  - `public struct ReleaseInfo: Sendable, Equatable { version, notes, zipURL, signatureURL }` with `static func parse(_ json: Data) throws -> ReleaseInfo`.
    - It reads `tag_name`, `body` and `assets[].name/browser_download_url`.
    - It requires both `Maclean-<version>.zip` and `.zip.sig`.
  - `public enum UpdateSignature { static func isValid(_ data: Data, signatureBase64: String, publicKeyBase64: String) -> Bool }`. It uses `Curve25519.Signing`, and returns false on any decode error.
  - `public enum InstallSource: Equatable { case homebrew, standalone }` with `static func detect(bundlePath: String, caskroomRoots: [String] = ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"]) -> InstallSource`.
  - `public static func shouldCheck(lastCheck: Date?, now: Date) -> Bool`, true when more than 24 h have passed.

- [ ] **Step 1: Tests**

```swift
@Test func versionsCompare()            // 0.2.0 < 0.3.0 < 0.10.0; "v0.3" == 0.3.0; "abc" == nil
@Test func parsesRelease()              // fixture JSON → version 0.3.0, zip/sig URLs
@Test func releaseWithoutSigRejected()
@Test func signatureVerifies()          // test key pair generated in test: valid sig → true; one byte flipped in data → false; garbage base64 → false
@Test func homebrewNeedsCaskroomAndPath()  // TempDir caskroom/maclean + "/Applications/Maclean.app" → homebrew; other path → standalone; no caskroom → standalone
@Test func checkThrottle()
```

- [ ] **Step 2:** Run T. The new tests fail.
- [ ] **Step 3:** Implement the code.
- [ ] **Step 4:** Run T. Everything passes.
- [ ] **Step 5:** Commit: `feat: update core versions, signatures, install source`.

---

### Task 6: Update controller, installer and sheet

**Files:**
- Create:
  - `Sources/Maclean/UpdateController.swift`
  - `Sources/Maclean/UpdateInstaller.swift`
  - `Sources/Maclean/UpdateSheet.swift`
  - `Sources/MacleanCore/UpdateKey.swift` (`public enum UpdateKey { public static let publicKeyBase64 }`, in Core so the root helper can verify too)
- Modify:
  - `Sources/Maclean/AppCommands.swift` (Maclean › "Check for Updates…" after About)
  - `Sources/Maclean/SettingsView.swift` (the `update.automatic` toggle)
  - `Sources/Maclean/MacleanApp.swift`
  - `README.md` (the privacy line from spec §5.5)
- Test: `Tests/MacleanAppTests/UpdateControllerTests.swift`

**Interfaces:**
- Consumes: Task 5 and Task 2 (`PromptCoordinator.requestUpdateSheet`).
- Produces:
  - `@MainActor @Observable final class UpdateController`:
    - `enum State: Equatable { case idle, checking, available(ReleaseInfo), upToDate, failed(String), downloading(Double), installing }`.
    - `init(currentVersion: String, bundleURL: URL, fetch: @escaping (URL) async throws -> Data, defaults: UserDefaults, coordinator: PromptCoordinator, installer: UpdateInstalling)`.
    - `func checkAutomatically()`: obeys `update.automatic`, the throttle and `update.skippedVersion`, and fails silently.
    - `func checkNow()`: always shows a result.
    - `func skip()`, `func later()`, and `func install() async`.
    - `var action: InstallAction { get }`, an enum with `.install`, `.installWithPassword`, `.brew` and `.download`. It is computed from `InstallSource` and whether the bundle's parent folder is writable. `.download` appears only after the password dialog was cancelled.
  - `protocol UpdateInstalling { func install(zip: Data, signature: String, release: ReleaseInfo, replacing bundleURL: URL) async throws }`. `UpdateInstaller` is the live implementation:
    - verify the signature with `UpdateKey.publicKeyBase64`;
    - `ditto -x -k` into a temp folder;
    - check the bundle id `org.maclean.Maclean` and that `CFBundleShortVersionString == release.version`;
    - move the old bundle to the Trash with `FileManager.trashItem`, move the new one into place, remove quarantine, then `Relauncher.relaunch(bundleURL:)`.
    - Each failure throws a typed error with a user message, and the old bundle stays when anything before the swap fails.
  - Install is refused while any `ScanSession.isDeleting` is true or Smart Clean is cleaning ("Finish the current delete first.").
- For now, `UpdateKey.publicKeyBase64` is a placeholder that fails verification. Task 7 sets the real key.

- [ ] **Step 1: Tests** (fake fetch and fake installer; TempDir for the real installer with a test key injected)

```swift
@Test func automaticCheckThrottledAndSilent()     // lastCheck 1 h ago → no fetch; fetch throws → state stays idle
@Test func skippedVersionSuppressesAutomaticOnly()
@Test func newerReleaseRequestsSheet()            // coordinator.sheet becomes .update after access sheet cleared
@Test func homebrewActionIsBrew()                 // and non-writable parent → .installWithPassword; after a cancel → .download
@Test func installRefusedDuringDelete()
@Test func installerRejectsBadSignature() async   // real UpdateInstaller with test key: tampered zip → throws, old bundle untouched
@Test func installerRejectsWrongBundleOrVersion() async
@Test func installerSwapsBundle() async           // TempDir "Applications/Maclean.app" replaced by new version; old in a test trash (inject trash closure)
```

- [ ] **Step 2:** Run T. The new tests fail.
- [ ] **Step 3:** Implement the code.
  - The sheet follows `password-and-update-v3.html`. It's wide enough that the three buttons never wrap (`fixedSize` on each button), and **Install and Relaunch** is the default action.
  - The automatic check runs after launch through the coordinator.
- [ ] **Step 4:** Run T and `scripts/build-app.sh`. Both pass.
- [ ] **Step 5:** Commit: `feat: auto-update from signed github releases`.

---

### Task 6b: Root install-update mode (password route)

**Files:**
- Create: `Sources/MacleanCore/AdminInstall.swift`
- Modify:
  - `Sources/maclean-scan/main.swift` (the `install-update` mode)
  - `Sources/Maclean/UpdateController.swift` and `UpdateInstaller.swift` (the `.installWithPassword` path through the `AdminBatcher` or the runner, with the reason "Maclean needs your password to update itself.")
- Test: `Tests/MacleanCoreTests/AdminInstallTests.swift`

**Interfaces:**
- Consumes:
  - Task 5 `UpdateSignature`, `SemanticVersion`;
  - `UpdateKey.publicKeyBase64` (Core);
  - `readVerifiedFile`;
  - Task 1 `AdminRunning`.
- Produces:
  - `AdminInstall.arguments(zip: String, zipSHA256: String, signature: String, signatureSHA256: String, version: String, target: String) -> [String]`, which gives `install-update --zip <p> --zip-sha256 <h> --sig <p> --sig-sha256 <h> --version <v> --target <path>`.
  - `AdminInstall.parse(_:) throws -> Request`.
  - `AdminInstall.perform(_ request: Request, publicKeyBase64: String, workDir: URL, unzip: (URL, URL) throws -> Void) -> Result<Void, InstallError>`, which runs these steps **in this order**:
    1. Read the zip and the signature with `readVerifiedFile` (hash, `O_NOFOLLOW`, regular file).
    2. Verify the signature.
    3. Unzip into `workDir`. In production this is a fresh root-owned 0700 directory under `/private/var/tmp`, made with `mkdtemp`.
    4. The unpacked bundle must be exactly one `Maclean.app`, with bundle id `org.maclean.Maclean` and `CFBundleShortVersionString == version`.
    5. The target must be canonical with no symlinked components (`realpath` equals target), end in `.app`, be an existing directory whose `Contents/Info.plist` has bundle id `org.maclean.Maclean`, and not be `/` or a volume root.
    6. Rename the target to `<target>.maclean-old-<uuid>` (same directory), then rename the new bundle into place. If that fails, rename the old one back. On success, remove the old copy.
    7. Remove `workDir`.
  - `InstallError` has a case and a user message per check.
  - The CLI mode requires uid 0, prints one JSON line `{ok}` or `{error}`, and writes nowhere except `workDir` and the target's parent.

- [ ] **Step 1: Tests** (TempDir; a test key pair; a fake "installed" `Maclean.app` built in TempDir; unzip with `ditto`)

```swift
@Test func installsVerifiedBundle()          // target replaced by new version, no *.maclean-old-* left, workDir gone
@Test func rejectsBadSignature()             // target untouched
@Test func rejectsTamperedFiles()            // zip bytes ≠ sha256 → refused before unzip
@Test func rejectsWrongBundleIdOrVersion()
@Test func rejectsTargetThatIsNotMaclean()   // target is another app / plain dir / symlinked path / "/" → refused, untouched
@Test func restoresOldOnFailedMove()         // simulate failure (unzip produces read-only parent?) → old bundle back in place
```

- [ ] **Step 2:** Run T. The new tests fail.
- [ ] **Step 3:** Implement the code. In the app, `.installWithPassword` writes the zip and the signature to 0600 files, runs the helper with the update reason, then relaunches. A cancel sets the action to `.download`.
- [ ] **Step 4:** Run T and `scripts/build-app.sh`. Both pass.
- [ ] **Step 5:** Commit: `feat: root install-update mode for password updates`.

---

### Task 7: Release tooling, signing, docs

**Files:**
- Create:
  - `scripts/update-key.swift` (`generate <keyfile>`, `public <keyfile>`, `sign <keyfile> <file>`, using CryptoKit, with the key stored as base64 raw representation in a 0600 file)
  - `scripts/make-signing-cert.sh`
- Modify:
  - `scripts/package-release.sh`
  - `Sources/MacleanCore/UpdateKey.swift` (the real public key)
  - `README.md` (Getting started: the Full Disk Access sheet and the password prompts; Settings; Releasing)
  - `docs/manual-checklist.md` (an "Access and updates" section)
  - this plan (Outcome)

**Interfaces:**
- `make-signing-cert.sh` creates the self-signed code-signing certificate "Maclean Release": OpenSSL with `extendedKeyUsage=codeSigning`, a 10-year validity, imported into the login Keychain with `security import … -T /usr/bin/codesign`.
  - It is idempotent: it exits 0 if `security find-identity -v -p codesigning` already lists it.
  - The owner runs it; it may ask for the Keychain password.
- `package-release.sh`:
  - uses `MACLEAN_SIGN_IDENTITY` (default "Maclean Release" if the Keychain has it, else fails with instructions);
  - signs the zip with `swift scripts/update-key.swift sign "$MACLEAN_UPDATE_KEY" <zip>` into `<zip>.sig`, where `MACLEAN_UPDATE_KEY` defaults to `~/.config/maclean/update-key`;
  - prints both paths and the zip's SHA-256.
- **Controller-run steps, not the implementer's:**
  - generate the owner's key with `swift scripts/update-key.swift generate ~/.config/maclean/update-key`, only if it is absent;
  - paste the public key into `Sources/MacleanCore/UpdateKey.swift`;
  - the owner runs `make-signing-cert.sh`.

- [ ] **Step 1:** Write the scripts. Test `update-key.swift` with a round trip in a temp dir: generate, sign a file, check that `UpdateSignature.isValid` accepts the public key (a small test in UpdateTests that shells out, or a documented manual command).
- [ ] **Step 2:** Update the README and checklist. The checklist must cover:
  - the Full Disk Access sheet on each launch without access, after revoking, and the Relaunch after granting;
  - one admin dialog naming Maclean after a scan of `/` (cancel, and allow);
  - Smart Clean measuring automatically;
  - the update from 0.3.0 to a test 0.3.1 release, keeping Full Disk Access;
  - a Homebrew install showing the brew command;
  - the root versus TCC spike from spec §6a.1: record what root reads with and without Full Disk Access.

  The README's Releasing steps also cover signing, and state that 0.2.0 users move to the first self-updating release by hand or with `brew upgrade` (spec §6a.4).
- [ ] **Step 3:** Run T and `scripts/build-app.sh`.
- [ ] **Step 4:** Commit: `docs: access and update guides, release signing tools`.

## Outcome and follow-ups

### Commits

Branch `plan-04-access-updates`, from `2954c6e`:
- Task 1, admin helper in-process with prompt: `f04a0c7`, `bb134c6` (per-invocation exit status in batches).
- Task 2, Full Disk Access sheet and prompt coordinator: `554e3fa`, `a2e6826`.
- Task 3, root read mode and tree graft: `50adb11`, `0c15510` (pin the restricted folder before the root scan).
- Task 4, admin reads in scans and Smart Clean: `9e801ca`, `ddf530a`.
- Task 5, update core (versions, signatures, install source): `5a341d9`, `2af1266`.
- Task 6, auto-update: `52d213e`, `8c8320f` (same-volume staging, safe rollback).
- Task 6b, root install-update mode: `f04e6f0` (plan), `f56964b`, `18fe74d` (refuse downgrades, strip ACLs).
- Task 7, release tooling, signing and docs: the commit this section ships in.

Tests at the end of Task 7: 473 pass (44 + 287 + 142 across the three test targets), including the new `UpdateKeyToolTests` (a real `generate`, `sign`, `public` round trip checked with `UpdateSignature.isValid`, and a forged identity-point signature rejected). `scripts/build-app.sh` builds. `package-release.sh` was exercised end to end with a temporary key and `MACLEAN_SIGN_IDENTITY=-`, and its missing-key failure was checked.

### Rulings worth remembering

- R1: `UpdateInstaller` takes injectable relaunch and trash closures. Tests never terminate the process or touch the real Trash.
- R2: the owner's update key and signing certificate are made by the owner, never by a subagent or the test suite.
- R3: updates that can't replace the bundle as the user ask for the administrator password (reverses §6a.2). The root helper re-verifies the Ed25519 signature (the public key lives in MacleanCore), unzips into its own 0700 directory, checks the bundle id and version, and swaps only an existing Maclean.app at the requesting app's path.
- R4: each invocation's exit status travels on its separator line in a batch, and a non-zero status fails that invocation.
- R5: `PromptCoordinator.admin` is `async throws`, so cancelled waiters never run.
- R6: Smart Clean's automatic measure runs on the launch check and user-initiated checks only, never the background re-check after a clean. A cancel suppresses it until the next user-initiated check.
- R7: `UpdateSignature.isValid` rejects an all-zero public key (CryptoKit accepts forged signatures for it), which protects the placeholder period and the root helper.
- R8: the root install work directory is a root-owned 0700 `mkdtemp` in the target's parent, with renames relative to the opened parent fd (same-volume swap). A hidden `.maclean-update-root-*` directory may remain in `/Applications` if root crashes mid-install.
- R9: the root install refuses downgrades (request version must exceed the installed one) and strips ACLs on the unpacked bundle.

### Deferred minors

- **Admin dialog and prompts:** NSAppleScript runs on a GCD worker, while Apple's note says main thread (check in the manual dialog checks); duplicated fake batching loop in tests; "1 system items" and "1 folders" are unpluralized.
- **Sheets and UI (unseen):** the access sheet set while the Smart Clean review sheet is up may not present (ancestor sheet), which gates admin invisibly; the update sheet has the same nesting concern; Clean is disabled while an automatic measure waits behind a sheet; a superseded measure still reaches the dialog and its result is dropped; full-tree walks run on the main actor.
- **Root read and graft:** hard links crossing a graft boundary are double-counted; stale `errno` in the pin non-directory branch; the over-cap case reuses the "outside the scan" message.
- **Update core and installer:** homebrew detection uses lexical standardizing (symlinked `/Applications` edge cases); `shouldCheck` lives on the `UpdateCheck` enum; a `Loader` continuation race when cancelled before start; the live `Loader` is untested; the timing-based stale-download test may flake; failed checks retry on each launch; a narrow delete-during-install race.
- **Root install:** old-bundle deletion as root over a user-owned tree is shared with `--delete`, and the XNU rename semantics are unverified; a leftover `.maclean-update-root-*` after a crash; the ownership test runs non-root only; the `.downgrade` message also covers an unparseable installed version; no test sets an ACL on a symlink entry.
- **Task 7:** only the all-zero key is refused by `UpdateSignature`. A real key that is a small-order point isn't rejected, but `generate` always makes a valid random key. `scripts/make-signing-cert.sh` was only syntax-checked and never run. It is marked executable in git's index, but run it as `sh scripts/make-signing-cert.sh`.

### Steps still owed by the owner

1. Run `sh scripts/make-signing-cert.sh` to create "Maclean Release" in the login Keychain (it may ask for the Keychain password). Check with `security find-identity -v -p codesigning`.
2. Generate the update key: `mkdir -p ~/.config/maclean && swift scripts/update-key.swift generate ~/.config/maclean/update-key` (only if absent). Back the file up.
3. Paste the printed public key into `Sources/MacleanCore/UpdateKey.swift` in place of the all-zero placeholder, and commit. Until then nothing installs.
4. Release 0.3.0 with `scripts/package-release.sh` and `gh release create` (zip and `.sig`), then bump the cask. Note in the release notes that 0.2.0 users update by hand or with `brew upgrade --cask maclean`.
5. Run the "Access and updates" section of `docs/manual-checklist.md`, including the root versus privacy-protection spike (record the results here), the 0.3.0 to 0.3.1 update that keeps Full Disk Access, and a real password update into a root-owned folder (the root-only chown and swap branches no automated test reaches).

### Developer ID follow-ups (spec §8)

With a Developer ID:
- notarize the app, so the quarantine workaround and the cask's postflight step go away;
- move administrator actions to an `SMAppService` privileged helper with Authorization Services, replacing the per-action AppleScript dialog and the root `install-update` mode;
- consider the self-declared `--context` (R31) closed at that point.
