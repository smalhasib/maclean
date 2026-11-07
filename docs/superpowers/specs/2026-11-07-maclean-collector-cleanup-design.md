# Maclean: Collector, Delete and Smart Clean (design)

Date: 2026-11-07
Status: awaiting owner approval
Builds on: `2026-11-07-maclean-design.md` (product spec; §5.7 Collector, §5.8 Delete, §6.6 Delete engine), `2026-11-07-maclean-app-shell-design.md` (Plan 2 UI), and the "Before Plan 3" list in `docs/superpowers/plans/2026-11-07-maclean-02-app-shell.md`.
Research: mole (github.com/tw93/mole), studied 2026-11-07. Notes are inline below; mole is MIT licensed, and Maclean reimplements its ideas in Swift without copying code.

## 1. Intent

Two features share one delete engine.

1. **The collector and delete**, exactly as DaisyDisk does them. The owner said "go with daisydisk style". The product spec §5.7/§5.8 already specifies this, and this document doesn't re-decide it.
2. **Smart Clean (new):**
   - When Maclean opens, it checks the Mac in the background for things that are safe to clean: caches, logs, developer build leftovers, old installers, leftovers of uninstalled apps, the Trash, and so on.
   - It then lists what it found, grouped and sized, and asks the user's permission before deleting anything.
   - The owner pointed to mole, a terminal cleaner, as the mechanism to copy and improve on.

**Why:** DaisyDisk shows you where space went but leaves the hunting to you. Most reclaimable space on a developer's Mac sits in the same few places every time, such as Xcode DerivedData, `~/Library/Caches`, `node_modules` in old projects and the Trash. The owner wants Maclean to find those automatically, the way mole does, but with a reviewable list instead of mole's delete-as-you-go.

**Success:** you open Maclean, and within a few seconds a card on the start screen says how much can be cleaned. You open it, see exactly what will go and why each item is considered safe, untick anything you want to keep, and press Clean. Nothing you didn't see and approve is touched.

## 2. Changes to the product spec

These are the owner's decisions made in this round:

- Remove the non-goal "Automatic 'smart clean' recommendations". Smart Clean is now a goal.
- Reword the first anti-goal: "Deleting anything the user did not explicitly approve, either by putting it in the collector or by leaving it ticked in the Smart Clean review, or deleting a path whose contents changed since it was measured without the user knowing."

## 3. Goals, non-goals, anti-goals

### Goals
- DaisyDisk-identical collector and delete (spec §5.7, §5.8), including the safety rules in §5.8.
- A Smart Clean check that runs automatically at launch (setting, on by default), plus on demand.
- Every Smart Clean item says what it is, why it's considered safe, its size and its age. The user approves the final list.
- Improve on mole where it is weak (§6.8).

### Non-goals (this round)
- **Running tools' own cleanup commands**, such as `npm cache clean`, `brew cleanup`, `go clean`, `xcrun simctl delete unavailable` or `nix-store --gc`. Smart Clean deletes known folders directly. *Designer's call:* owner commands are opaque bulk actions that are hard to preview. Add them later if wanted.
- **Time Machine `.inProgress` backups and other users' home folders.** Maclean refuses anything on Time Machine volumes (spec §5.8). Smart Clean covers the current user and system-wide folders (§6.2a), never other accounts. *Designer's call.*
- **App uninstaller**, memory/"optimize" tweaks, scheduled background cleaning, and a menu-bar agent.
- **Local snapshots and purgeable space**: Plan 4 (hidden space), as already planned.

### Anti-goals
- **A launch check that slows down or blocks the app.** It runs in the background at utility QoS and must never delay the start screen.
- **Deleting a cache while its app is running**, deleting user content (documents, git-tracked files, keychains, mail, messages attachments, photos), or deleting anything outside the catalog's patterns.
- **Nagging.** There are no badges or notifications, and the check never re-runs while the user is working. The card simply sits on the start screen.

## 4. Part 1: Collector and delete

Behaviour is as in spec §5.7, §5.8 and §6.6. This section adds only the decisions the spec left open and folds in the Plan 2 follow-ups.

### 4.1 Model
- **TreeView overlay.** The immutable `FileTree` gets an overlay holding the set of collected nodes and the set of removed (deleted) nodes. It exposes `effectiveSize(of:)` and `visibleChildren(of:)`, sorted by effective size. SunburstLayout, the side list, labels and breadcrumbs read through it.
  - Effective sizes are updated incrementally up the ancestor path.
  - The size-order cutoffs in SunburstLayout must use effective sizes.
  - Removed nodes are permanent for that result. Collected ones can be restored.
- **Collector and overlay belong to the scan session (`ScanSession`), not the window.** *Designer's call.*
  - Every window showing the same session shares one collector and one overlay. A folder collected in one window disappears in all of them.
  - The spec says "global across navigation within a scan result". In window-per-scan mode, each session's windows show that session's collector.
  - **Rescan:** collected paths that still exist in the new tree carry over, re-keyed to the new inode, device and size, since the user now sees the new scan. Paths missing from the new tree are dropped, and a one-line note says how many. Removed marks are cleared, because the new tree reflects reality.
  - **Forget Scan Result:** clears the collector. If it holds items, the user confirms first.
  - Closing a window doesn't touch the session's collector.
- **Collector item key.** Each item is keyed by (session, path) and records the inode, device and the scanned size.
- **Collect-time refusals.** Protected paths (§5.8 rule 2) are refused when collected, with a one-line message in a small popover anchored to the collector bar. "Smaller objects" segments are refused too. The refusal rules live in one `ProtectionRules` type in MacleanCore, shared with Smart Clean (§6.4).

### 4.2 UI (light & airy, as Plan 2)
- **The bar,** in each result window:
  - Empty state as now, a dashed circle with a hint.
  - When the collector has items, the circle fills with a proportional ring and shows the total. Beside it reads "<size> collected" and a red **Delete** button.
- **Expanded panel.** Clicking the circle expands a panel upward over the bottom of the chart, up to 40% of the window height, listing items as name, path tail and size.
  - Each row has an × button and a context menu (§5.7).
  - Items can be dragged back out to the chart to restore them.
- **Collecting.** Drag and drop works from the chart, the list and Finder. A Finder drop is accepted only if the path lies inside the scanned root and is visible in the tree; otherwise it's refused with a message.
  - ⌘⌫ toggles the item under the pointer.
  - Also available: context menu › Move to Collector, and Action › Move All Items from Current Folder to Collector.
- **Animation.** Collect and uncollect re-lay out the chart with an angle morph keyed by NodeID, about 250 ms. This is the Plan 2 follow-up "relayout without navigation".
- **Delete flow.**
  - Pressing Delete replaces the bar's contents with a 5-second countdown ("Deleting 12 items, 4.2 GB in 5…") and a Cancel button.
  - Then a progress line and a Stop button. Stopping happens between items.
  - At the end, a summary sheet: freed size, plus a list of "changed since scan" items (Delete anyway / Skip, per item and for all) and failures with reasons. Failed and skipped items stay in the collector.
- **Menu validation.** Delete Collected Items is enabled only when the collector is non-empty and no delete is running (`NSMenuItemValidation`).

### 4.3 Delete engine (MacleanCore, shared with Smart Clean)
- **Input:** a list of `DeleteRequest`, each with path, expected inode/device, the expected size and file count (for folders), and the mode (permanent or Trash, from Settings).
- **Per item, in order:**
  1. Protection check (`ProtectionRules`).
  2. `lstat` identity check. Never follow a symlink; a symlink is deleted as a link.
  3. Folder re-walk to compare file count and allocated size with the expected values. Any difference returns `.changedSinceScan(current:)` without deleting. *Designer's call:* a tolerance of 0 files and 1% or 1 MB of size, whichever is larger, because caches touch atime/metadata.
  4. Delete.
     - **Permanent:** a bottom-up `unlinkat`/`rmdir` walk relative to directory fds opened with `O_NOFOLLOW`, so a symlink swapped in mid-delete can't redirect it. This closes mole's acknowledged check-then-use race.
     - **Trash:** `FileManager.trashItem`.
  5. `EACCES`/`EPERM` → collected into an admin batch. After the normal pass, one admin prompt deletes the whole batch through the bundled CLI (`maclean-scan delete --expect <ino:dev> <path>`…), run via `osascript … with administrator privileges`. The CLI re-runs steps 1–4 itself as root.
- **Output:** a per-item result, one of `.deleted(freed:)`, `.changedSinceScan`, `.refused(reason)`, `.failed(errno message)` or `.cancelled`. The tree overlay marks deleted nodes removed. The start screen's free space refreshes.
- **Hard links:** freed size counts only bytes actually released. The tree already counts each inode once, so a deleted node's scanned size is used as is.

## 5. Part 2: Smart Clean, behaviour

### 5.1 When it runs
- **At launch,** after the start screen appears, in the background (utility QoS), if Settings › General › "Check for cleanable items at launch" is on (default on).
- **On demand:** Action › Check for Cleanable Items (⇧⌘K), and a "Check again" button in the review.
- It never runs while a disk scan of the same volume is running. If a scan starts, the check pauses and resumes after. *Designer's call:* this avoids two walkers competing for the same disk.
- **Time budget:** the whole check targets under 10 s on the owner's Mac. Each target has its own budget of 5 s; a target that exceeds it shows "size unknown", is unticked, and the check moves on.

### 5.2 Where results appear
- **A card on the start screen** below the disk list: an icon, "**18.6 GB** can be cleaned", a one-line breakdown of the top 3 categories, and a **Review…** button.
  - While checking it shows "Checking for cleanable items…" with a small spinner.
  - With nothing found it shows "Nothing to clean right now" and fades after a few seconds.
  - The card is hidden while a result fills the window in one-window mode.
- **Review** opens a sheet on the main window (in window-per-scan mode, on the start window). *Designer's call.* The sheet contains:
  - **Header:** the total selected ("12.1 GB selected of 18.6 GB found") and a **Clean** button (red, disabled when nothing is ticked).
  - **Category sections** (§6.2), each with a tri-state checkbox, name, total size and a disclosure. Each row shows:
    - checkbox, icon, name and the path (middle-truncated);
    - size and age ("last used 3 months ago");
    - a short reason in secondary text ("Cache, rebuilt automatically" / "Project not built in 45 days").
  - **Row context menu:** Show in Finder, Open in Terminal, Quick Look, "Never clean this" (§5.5).
  - **Default ticks:** Safe items are ticked. Review items are shown but unticked. Info items have no checkbox; they carry a "Show in Finder" and a "Scan this folder" link that opens it in the sunburst. All three tiers are defined in §6.1.
  - **Skipped section:** a collapsed "Skipped (n)" list at the bottom names what was found but not offered, and why: app running, recent, protected, no access (needs Full Disk Access), never-clean list. This makes protection visible, which mole does not.
- **Permission:**
  - Pressing Clean shows a confirmation alert: "Delete 214 items (12.1 GB)?", the deletion mode in one line ("They will be deleted permanently" / "moved to the Trash"), and the Clean and Cancel buttons.
  - Then the same delete engine runs with progress and a Stop button, followed by the same summary as the collector.
  - *Designer's call:* an alert replaces the 5-second countdown here, since the review already listed every item. The collector keeps DaisyDisk's countdown.
- **Deletion mode:** the Settings toggle "Move to Trash instead of deleting permanently" applies to both the collector and Smart Clean (default off, matching the owner's "Permanent, like DaisyDisk"). The Trash category itself is always deleted permanently, since that's what emptying means.

### 5.3 Interaction with open scan results
After a Smart Clean delete, any open scan result containing a deleted path marks that node removed through the overlay (§4.1), so the map shrinks without a rescan. A path is found with `node(atPath:)` plus an inode/device match. Results whose root contains no deleted paths are untouched.

### 5.3a System-wide folders (owner's decision)
- **Included.** System-wide targets (§6.2a) are part of every check.
- **Measuring.** The launch check runs as the user and measures what it can read; most system logs and caches are readable with Full Disk Access.
  - Anything it can't read is still listed, marked "size unknown", unticked.
  - A **Measure with administrator rights** button sits at the top of that group. It runs the bundled CLI as root once (`maclean-scan smart-measure <paths>`, via the §6.5 `osascript` path, one password prompt) and fills in the sizes, ages and identities.
  - The launch check itself **never** asks for a password.
- **Deleting.** Ticked system items go into the admin batch (§4.3 step 5). There is **one password prompt** for the whole Clean, shown after the confirmation alert. The alert says "Some items need your administrator password."
- **Root re-checks.** The root CLI re-runs Smart Clean protection, identity and age checks itself before each delete. It accepts only paths matching a system rule in the catalog, which is compiled into MacleanCore and shared by app and CLI. So even a tampered request can't make it delete anything else.
- **Cancelled password prompt:** those items show as "skipped: administrator password not given". Everything else proceeds.

### 5.4 Full Disk Access
Without Full Disk Access, some targets can't be read: other apps' containers, Mail Downloads and the Trash. These go to Skipped as "needs Full Disk Access", with a link to the existing FDA guide. Plan 4 builds the full onboarding; Plan 3 links to System Settings.

### 5.5 Never-clean list
- "Never clean this" adds the path to a list stored in `UserDefaults` (`smartClean.neverClean`, an array of absolute paths). A Settings › Smart Clean tab shows the list with remove buttons.
- A never-clean entry protects its own path, its descendants and its ancestors from a parent sweep. That's mole's rule, and it's a good one.
- The Smart Clean Settings tab also holds the launch-check toggle and category toggles (one per category, all on).

## 6. Part 2: Smart Clean, mechanism

### 6.1 Rules as data
- **The catalog** is a Swift array of `CleanRule` values in MacleanCore. A rule holds:
  - an id and a category;
  - the root path pattern (`~`-relative), with an optional single `*` glob segment, for example `~/Library/Containers/*/Data/Library/Caches`;
  - the unit offered: the matched folder itself, or each child of it;
  - a tier;
  - age and owner conditions (§6.3);
  - a reason string.
- **Tiers:**
  - **Safe:** regenerated automatically, no user content. Ticked by default.
  - **Review:** safe to delete, but costs something, such as a rebuild, a re-download, or losing window restoration. It may also be a heuristic, such as orphan leftovers. Unticked by default.
  - **Info:** large data Maclean won't delete from Smart Clean, such as iOS backups, Xcode Archives, Docker/VM images, `~/.m2`, `~/.gradle/caches` and local LLM models. Shown only so the user knows; deleting goes through the collector.
- **The engine is generic.** It expands patterns, applies conditions, sizes, and classifies. Adding a target means adding one rule. Tests feed fake rules against temp directories.

### 6.2 Catalog (v1, user-level)

Ages are "nothing inside modified for N days" unless stated. "Owner" means the item is skipped while the named app (by bundle id) is running.

| Category | Target | Unit | Tier | Condition |
|---|---|---|---|---|
| App caches | `~/Library/Caches/*` | each child | Safe | **Improvement on mole:** untouched ≥ 3 days; owner = the child's name if it's a reverse-DNS bundle id; excluded per §6.4. Children not named like a bundle id: Safe if ≥ 7 days. A bundle-id child whose app isn't installed goes to the leftovers rule instead (see rule order below). `com.apple.*` children are offered only from this allowlist: `com.apple.Safari`, `com.apple.dt.Xcode`, `com.apple.WebKit.*`, `com.apple.QuickLook.thumbnailcache`, `com.apple.iconservices.store`, `com.apple.akd`, `com.apple.photoanalysisd`, `com.apple.helpd`, `com.apple.Suggestions`, `com.apple.IdentityCaches`, `GeoServices`, `com.apple.ap.adprivacyd`. Other Apple caches go to Skipped ("macOS system cache") |
| App caches | `~/Library/Containers/*/Data/Library/Caches/*` | each child | Safe | untouched ≥ 3 days; owner = the container's bundle id; container not protected |
| App caches | Electron/Chromium app caches in `~/Library/Application Support/*/`: `Cache`, `Code Cache`, `GPUCache`, `DawnCache`, `GrShaderCache`, `Crashpad/completed` | each match | Safe | owner = the app whose folder it is (by name → bundle id via LaunchServices; unknown owner means skip) |
| Browsers | Safari, Chrome, Edge, Brave, Arc, Firefox, Vivaldi, Opera: per-profile `Cache`, `Code Cache`, `GPUCache`, `ShaderCache` | each match | Safe | owner = the browser; never history, cookies, or profiles |
| Logs | `~/Library/Logs/*` (including `DiagnosticReports` contents) | each child | Safe | ≥ 7 days |
| Developer | `~/Library/Developer/Xcode/DerivedData/*` | each project folder | Safe if ≥ 14 days, Review if newer | owner = Xcode (`com.apple.dt.Xcode`); show the project name from `info.plist` `WorkspacePath`. **Improvement:** mole deletes all with no age limit |
| Developer | `~/Library/Developer/Xcode/iOS DeviceSupport/*` (and macOS/watchOS/tvOS/visionOS) | each version | Review | keep the 2 newest by mtime |
| Developer | `~/Library/Developer/CoreSimulator/Caches/*`, `~/Library/Logs/CoreSimulator/*` | each child | Safe | owner = Simulator |
| Developer | package caches: `~/.npm/_cacache`, `~/Library/Caches/Yarn`, `~/Library/Caches/pnpm` (metadata only), `~/Library/Caches/pip`, `~/.cache/pip`, `~/.cargo/registry/cache`, `~/.rustup/downloads`, `~/Library/Caches/Homebrew/downloads`, `~/.gradle/{daemon,workers,notifications}`, `~/Library/Caches/org.swift.swiftpm`, `~/Library/Caches/CocoaPods`, `~/.cache/{typescript,electron,node-gyp}`, `~/go/pkg/mod/cache/download` | the folder | Review | re-download cost; Homebrew skips `*.incomplete`; Gradle requires no running Gradle daemon (process name check). Note: some of these sit inside `~/Library/Caches` and are claimed here, not by the generic app-caches rule (first matching rule wins, specific before generic) |
| Project leftovers | build artifacts in project folders (§6.5) | each artifact | Safe if ≥ 30 days untouched, Review if 7–30, Skipped if < 7 | §6.5 protections |
| Old installers | `/Applications/Install macOS*.app` | the app | Review | ≥ 14 days old and its version differs from the running OS. Deleting it may need admin, so it uses the admin batch |
| Old installers | `~/Downloads/*.{dmg,pkg}` | each file | Review | ≥ 30 days since added; the reason says "Installer image downloaded N days ago" |
| Leftovers of removed apps | `~/Library/Caches/<bundle-id>`, `~/Library/Logs/<bundle-id>`, `~/Library/Saved Application State/<bundle-id>.savedState`, `~/Library/Containers/<bundle-id>` (whole container), `~/Library/Application Support/<bundle-id or app name>` | each | Review | §6.6 orphan test. **Improvement:** containers and Application Support are offered, but only as Review, with the guessed app name and last-modified date shown |
| Window state | `~/Library/Saved Application State/*.savedState` | each | Review | ≥ 30 days; owner = its app |
| Trash | `~/.Trash/*` | the whole Trash as one row (expandable) | Review | needs Full Disk Access; always permanent |
| Mail attachments cache | `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/*` | each folder | Review | ≥ 30 days; owner = Mail |
| *System-wide rows are in §6.2a.* | | | | |
| Large data (info) | `~/Library/Application Support/MobileSync/Backup`, `~/Library/Developer/Xcode/Archives`, `~/Library/Containers/com.docker.docker`, `~/.orbstack`, `~/.m2/repository`, `~/.gradle/caches`, `~/.ollama/models`, `~/.cache/lm-studio`, `~/Library/Developer/CoreSimulator/Devices` | the folder | Info | none |

### 6.2a Catalog, system-wide (owner's decision: included)

All rows need admin to delete, and some need it to measure (§5.3a). Ages are "nothing inside modified for N days".

| Category | Target | Unit | Tier | Condition |
|---|---|---|---|---|
| System logs | `/Library/Logs/*` (including `DiagnosticReports` contents) | each child | Safe | ≥ 7 days |
| System logs | `/private/var/log/*` regular files matching `*.log`, `*.log.*`, `*.gz`, `*.bz2` (not directories, not `asl`) | each file | Safe | ≥ 7 days; not open (open-file check) |
| System logs | `/private/var/db/diagnostics/{Persist,Special,HighVolume}/*` | each file | Review | ≥ 7 days. The reason says "Older unified log history; Console loses entries older than this" |
| System logs | `/private/var/db/reportmemoryexception/MemoryLimitViolations/*` | each | Safe | ≥ 30 days |
| System caches | `/Library/Caches/*` | each child | Review | ≥ 7 days; `com.apple.*` excluded except `com.apple.iconservices.store`. Owner = the child's bundle id if any app or daemon with that id is running (`launchctl`-free check: running process whose executable's bundle id matches) |
| System caches | current user's Darwin cache dir (`confstr(_CS_DARWIN_USER_CACHE_DIR)`): `com.apple.metal`, `com.apple.metalfe`, `com.apple.gpuarchiver` | the folder | Safe | nothing modified in the last 1 day; skipped if an EDR/MDM vendor folder is present (§6.4). This is user-owned and needs no admin; it's listed here because it lives under `/private/var/folders` |
| System caches | `/private/var/folders/*/*/T/com.apple.idleassetsd/CFNetworkDownload_*.tmp` | each file | Safe | ≥ 7 days; not open |
| Leftover system services | `/Library/LaunchDaemons/*.plist`, `/Library/LaunchAgents/*.plist`, `/Library/PrivilegedHelperTools/*` not named `com.apple.*` | each | Review | the plist's `Program`/`ProgramArguments[0]` is an absolute path that no longer exists, or the helper's owning app (from its embedded `SMAuthorizedClients`/Info.plist bundle id) isn't installed (§6.6). The reason names the missing program |

**Never offered, even with admin:**
- `/Library/Updates` and `macOS Install Data`;
- `/private/var/db` outside the two rows above (including `uuidtext`);
- `/private/var/vm`, `/System`, `/usr`;
- any `com.apple.*` LaunchDaemon;
- other users' `/private/var/folders` entries.

**`/private` allowlist:** Smart Clean may touch only:
- `/private/var/log`
- `/private/var/db/diagnostics`
- `/private/var/db/reportmemoryexception`
- the current user's `/private/var/folders/<x>/<y>` cache and temp dirs.

**Rule order (first match wins):**
1. Never-clean entries and protection.
2. Specific rows: browsers, developer rows (including package caches inside `~/Library/Caches`), Mail Downloads.
3. **Leftovers of removed apps.** These come before the generic sweeps so that a cache, log, or saved state of an uninstalled app is offered as Review with the 30-day rule, never as Safe and ticked.
4. Window state.
5. The generic app-caches and logs sweeps.

The builder may add targets from mole's list in the same shape: user-level, path-based, with the same tiers and guards. They must not add sweeps of user history such as recent-items lists, which mole deletes and Maclean deliberately doesn't. *Designer's call.*

### 6.3 Conditions and probes
- **Age:** the newest of mtime and ctime of the item and everything inside it, from the same walk that sizes it, with no extra pass. "Untouched ≥ N days" compares that against now.
- **Owner running:**
  - The owner counts as running if `NSWorkspace.shared.runningApplications` contains its exact bundle id, or an app whose bundle id has it as a prefix (helpers such as `com.google.Chrome.helper`).
  - For containers, an additional `proc_listpidspath`-style open-file check on the target folder.
  - **Unknown means keep:** if a probe fails, the item goes to Skipped as "couldn't confirm the app is closed".
  - **Improvement on mole:** mole uses fuzzy `ps` grep.
- **Re-check at delete:** Smart Clean items become `DeleteRequest`s carrying the identity, size and count measured during the check. The delete engine's changed-since-measured rule (§4.3 step 3) applies.
  - The owner-running probe is re-run just before each item.
  - The tolerance for Safe-tier caches is relaxed: a changed cache is still deleted unless it grew by more than 10%. *Designer's call:* caches change constantly, and a re-confirm prompt for every cache would be noise. Review and Info items use the strict rule.

### 6.4 Protection (`ProtectionRules`)
- **One type with two rule sets.** It's called as `check(path, context: .collector | .smartClean)`. *Designer's call.*
- **Collector context:** only spec §5.8 rule 2, plus the unsafe-path-shape check without the ancestor-symlink rule. The collector deletes the item itself with `lstat` and fd-relative deletion, so a symlinked ancestor can't redirect it. This keeps DaisyDisk's freedom: Photos libraries, Mail, Messages attachments, `~/Library/Caches` and so on stay collectable. The never-clean list does **not** apply to the collector.
- **Smart Clean context:** everything below.

In the Smart Clean context, a path is refused if any of the following hold:
- **Spec §5.8 rule 2:** SIP paths, volume roots, `/Library` itself, the home folder itself, Maclean itself, Time Machine volumes.
- **Unsafe path shape:** relative, contains a `..` component or control characters, or the path or any ancestor is a symlink. Ancestors are resolved with `realpath`, and the deny checks re-run on the result; the resolved path can only deny, never allow.
- **Critical root:** an exact critical root (`/`, `/Applications`, `/Users`, `/Users/<anyone>`, `/Users/Shared`, `/Volumes`, `/opt/homebrew`, `/etc`, `/private/var/db`, …). Case variants are matched by inode.
- **Personal data:** Keychains, Accounts, Mail (except Mail Downloads), Messages (Attachments), Calendars, Contacts, Photos libraries, `Mobile Documents` (iCloud Drive), Safari history/bookmarks, browser profile data other than cache folders.
- **Never-clean list:** the path is on it, or is an ancestor or descendant of an entry (§5.5).
- **Smart Clean only:**
  - bundle ids in a protected list, ported from mole's `DATA_PROTECTED_BUNDLES` and `SYSTEM_CRITICAL_BUNDLES` (password managers, input methods, VPNs, `com.apple.*` except the specific caches in §6.2);
  - SQLite files that are open;
  - EDR/MDM vendor folders.

Port mole's `tests/fuzz_corpus/dangerous_paths.txt` (127 paths) as a Swift test. Every entry must be refused in the Smart Clean context. In the collector context, every entry that §5.8 rule 2 or path shape covers must be refused, such as system roots, traversal and control characters. Entries that are merely user data, such as Keychains, are collectable as in DaisyDisk, and the test lists them explicitly. *Note:* the corpus is MIT licensed; keep its licence notice in the test resource.

### 6.5 Project leftovers (mole's `purge`)
- **Search roots:**
  - `~/{Projects,Developer,Development,Code,Work,dev,src,GitHub,Repos,Workspace,www}`, whichever exist;
  - plus any top-level folder in `~` that contains a project marker within depth 2 (not Library/Movies/Music/Pictures/Public/Applications/hidden);
  - plus user-added roots in Settings › Smart Clean.
- Depth 1–6. Prune `.git`, `Library`, `.Trash`. Skip cloud-only placeholder (dataless) files.
- **Project markers:** `package.json`, `Cargo.toml`, `go.mod`, `pyproject.toml`, `requirements.txt`, `pom.xml`, `build.gradle(.kts)`, `Gemfile`, `composer.json`, `pubspec.yaml`, `Package.swift`, `*.xcodeproj`, `Makefile`, `build.zig`, `.git`.
- **Artifact names** (a directory, directly beside a marker):
  - `node_modules`, `target` (with `Cargo.toml` or `pom.xml`), `.build` (with `Package.swift`), `build` and `dist` (with `package.json`, `build.gradle`, `pubspec.yaml` or `CMakeLists.txt`);
  - `.gradle`, `.next`, `.nuxt`, `.svelte-kit`, `.angular`, `.turbo`, `.parcel-cache`, `.dart_tool`, `.zig-cache`, `zig-out`, `Pods` (with `Podfile`), `.venv`/`venv` (with `pyproject.toml` or `requirements.txt`), `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `.tox`, `coverage`.
  - **Improvement on mole:** `target`/`build`/`dist`/`bin`/`vendor` require the matching marker, not just the name. `bin`, `obj` and `vendor` are left out of v1.
- **Kept (Skipped, with reason)** if:
  - it contains `.git`;
  - it contains git-tracked files (`git ls-files -z -- <artifact>` in the repo; a timeout means keep);
  - a process has its cwd inside the project (`proc_pidinfo` cwd scan);
  - it is a `node_modules` whose lockfile install record is missing or older than a file inside it (mole's local-patch rule).
- **Nesting:** only the outermost artifact is offered. Rows are grouped by project, showing the project name and "last touched N days ago".

### 6.6 Leftovers of removed apps
- **Installed set:**
  - the bundle ids of `.app` bundles up to depth 3 in `/Applications`, `/System/Applications`, `~/Applications`, Homebrew Caskroom, and Setapp;
  - plus `NSWorkspace` running apps;
  - plus every id LaunchServices knows (`LSCopyApplicationURLsForBundleIdentifier` returning any URL, on any volume);
  - plus user LaunchAgent labels.
- **A candidate is offered only if all hold:**
  - its id isn't installed by any of those tests;
  - it isn't protected;
  - it doesn't match never-delete words (1password, keychain, bitwarden, ssh, gpg…);
  - it has been untouched for ≥ 30 days.
- If any probe fails, the whole category goes to Skipped ("couldn't check installed apps").
- The row shows the guessed app name (from the bundle id's last component, or a cached `CFBundleName` if one is found in the leftover's plist) and the last-modified date.

### 6.7 Sizing
- **One walk per item:** the `getattrlistbulk` reader from MacleanCore's scanner, used in a single-subtree mode. It counts allocated size, doesn't cross devices or follow symlinks, and counts each hard-linked inode once per check.
- **APFS clones:** a clone-shared extent counts once across the check, the same rule as the scanner.
- The check reuses an open scan result when it covers the path and is less than 10 minutes old. Otherwise it walks. *Designer's call;* this optimisation is optional.

### 6.8 Where Maclean improves on mole (summary)
1. **Review before delete.** mole deletes as it scans.
2. **Age gates on broad sweeps.** mole sweeps every cache, log and saved state with no age limit.
3. **Exact owner detection** by bundle id instead of `ps` grep, with "unknown means keep".
4. **Visible protection.** The Skipped list says why each item wasn't offered.
5. **A Never-clean toggle** on each row, instead of a hidden whitelist text file.
6. **Marker-qualified build-artifact names**, so `build/`, `dist/` and `target/` folders that aren't build output survive.
7. **fd-relative deletion,** which closes the symlink-swap race mole documents.
8. **Trash option** for everything except the Trash itself.
9. **Recent-items history is left alone.**

## 7. Constraints
- Everything in the product spec §3 applies: no developer account, macOS 14, Swift 6, ad-hoc signed.
- **No new dependencies.**
- **Tests never touch real user paths.** Rule tests run against a fake home directory, which means the catalog roots, including the system roots (`/Library`, `/private/var`, `/Applications`), must be resolvable against an injected base URL. The root CLI paths are tested as the normal user against temp folders. Owner-running and installed-app probes are injected protocols with fakes in tests.
- The launch check must not block the main thread, and must not add measurable time to first frame (Plan 2 measured 31.86 ms).

## 8. Suggested build order (the builder may split differently)
1. **Plan 3a: collector and delete.**
   - The Plan 2 prerequisites: TreeView overlay, relayout morph, `NSMenuItemValidation`, SunburstView split, shared helpers, and an app test target.
   - Collector model and UI, `ProtectionRules`, delete engine (fd-relative, Trash mode, changed-since-scan, admin batch via the CLI), countdown, summary, and the Settings Trash toggle.
2. **Plan 3b: Smart Clean.**
   - Rule engine and probes; catalog; project leftovers; app leftovers.
   - Launch check, start-screen card, review sheet, Skipped list, never-clean list, Settings › Smart Clean, and overlay updates of open results.
   - System-wide rows: `maclean-scan smart-measure` and the catalog-restricted root delete (§5.3a, §6.2a).

## 9. Left to the builder
- Exact visual styling of the card, review sheet, countdown and summary, within the Plan 2 light & airy language (both appearances, readable, uncluttered, keyboard accessible: Space toggles a row's checkbox, Return activates Clean only after focus is on it).
- Exact icons per category, and copy wording.
- Internal type names beyond `CleanRule`, `DeleteRequest`, `ProtectionRules`.
- Whether the review sheet uses `Table` or `List` / `OutlineGroup`.

## 10. Calls made after the builder check
- The collector's protection is DaisyDisk-narrow, and Smart Clean's is strict (§6.4).
- The collector and overlay are per scan session, with rescan carry-over by path (§4.1).
- Leftovers rules run before the generic sweeps (§6.2 rule order).
- **System-wide folders (owner's request after the first draft).**
  - The system rows (§6.2a) are mostly Review tier, apart from logs and GPU caches.
  - The launch check never asks for a password; admin rights are needed only to measure unreadable items or to delete.
  - The root CLI only deletes paths that match a catalog system rule.
- `com.apple.*` caches are offered only from an allowlist (§6.2).

## 11. Open questions
None.
