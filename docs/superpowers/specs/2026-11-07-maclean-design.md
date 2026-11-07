# Maclean — Design

Date: 2026-11-07
Status: awaiting owner approval

## 1. Intent

Maclean is a free, open-source macOS disk-space analyzer and cleaner. It reproduces the full feature set of DaisyDisk (v4): scan a disk or folder, show it as an interactive sunburst map, navigate into any folder, collect files/folders from anywhere into one global list, then delete everything in that list in one go. It also offers quick actions such as Open in Terminal.

**Why:** the owner uses DaisyDisk daily and wants the same workflow as an open-source tool anyone can use, with no trial or licence.

**What success looks like:** someone used to DaisyDisk can switch to Maclean and find every feature they rely on. It is at least as fast (a ~420 GB / millions-of-files startup disk scans in well under a minute on Apple Silicon) and stays lightweight (a native app of a few MB).

## 2. Goals, non-goals, anti-goals

### Goals
- Feature parity with DaisyDisk v4 (full list in §5), observed directly in the app on 2026-11-07 and from its user guide (`docs/research/daisydisk-guide-notes.md`).
- Native, lightweight: Swift + SwiftUI/AppKit, no bundled web runtime.
- Safe deletion that strangers can trust on their own disks.
- Open source on GitHub, MIT licence.

### Non-goals
- Selling it, trial/registration/licence screens, "Buy Now" UI.
- Mac App Store distribution (the sandbox makes full-disk scanning impossible).
- Windows/Linux.

### Anti-goals (failure even if it "works")
- Deleting anything the user did not explicitly approve (put in the collector, or left ticked in the Smart Clean review), or deleting a path whose contents changed since it was measured without the user knowing. (Revised 2026-11-07: Smart Clean added; see `2026-11-07-maclean-collector-cleanup-design.md`.)
- Damaging macOS: deleting system-protected locations.
- Copying DaisyDisk's name, icon, logo, wording or exact visual styling. Maclean clones *behaviour*, with its own identity (own palette, icon, copy).
- Feeling heavy: Electron-class memory, slow launch, janky chart animation.
- Telemetry. Maclean collects no analytics. (DaisyDisk has an opt-in analytics checkbox; Maclean leaves it out. *Designer's call.*)

## 3. Constraints

- **No Apple Developer account.** Builds are ad-hoc signed and not notarized. Consequences, all accepted:
  - First launch is blocked by Gatekeeper; the user approves it once via System Settings › Privacy & Security › Open Anyway. The README documents this, plus build-from-source.
  - Full Disk Access (TCC) is tied to the code signature, and ad-hoc signatures change every build. After each update the user must grant Full Disk Access again. The app must detect missing access and guide the user (§5.10).
  - No SMAppService privileged helper. Admin scanning uses the standard admin-password prompt instead (§6.5).
  - Homebrew: the official cask repository disables casks that fail Gatekeeper (in effect since Sept 2026). Distribution is GitHub Releases (`.dmg`) plus build from source. A Homebrew tap is out of scope for v1.
- **Minimum macOS: 14 Sonoma.** *Designer's call:* mature SwiftUI `Observation`, `Canvas`, and `Table`; covers the vast majority of active Macs.
- **Language: Swift 6.** The owner asked for the most lightweight option; native Swift is it.
- **Architecture targets:** Universal (Apple Silicon + Intel).
- Never run destructive tests against real user paths; delete-related tests use temp directories only.

## 4. Decisions made with the owner

| Decision | Choice |
|---|---|
| Scope | Clone every DaisyDisk feature |
| Stack | Most lightweight → native Swift |
| Distribution | Open source, free, no plan to sell |
| Apple Developer account | No; ad-hoc signed builds |
| Name | Maclean |
| Delete | Permanent after 5 s countdown, like DaisyDisk |
| Cloud scan | Later, not in v1 |

## 5. Feature specification

Behaviour below was observed in DaisyDisk 4 on the owner's Mac unless marked otherwise.

### 5.1 Start screen ("Disks and Folders")
- One row per mounted volume: icon, name, capacity and description (e.g. "494.4 GB encrypted startup disk"), a usage bar, and the free-space figure (free + purgeable).
- Primary button **Scan**. Once a scan result exists it becomes **View**, which opens the stored result instantly. A split dropdown on the button offers: Rescan, Quick Rescan as Administrator, Forget Scan Result, Show in Finder, Get Info.
- While scanning, the row shows a progress bar, "scanning…", and **Cancel**.
- **Scan Folder…** opens a folder picker; that folder is scanned like a disk. Dropping a folder onto the window or onto the Dock icon also works. *Designer's call.*
- **Scan Cloud ▾** (Dropbox, Google Drive, OneDrive, Box). See §5.12.
- The volume list updates live as disks mount and unmount.

### 5.2 Scan result window layout
- Toolbar: back/forward arrows, then a breadcrumb trail starting with "Disks and Folders" › volume › … › current folder. Each crumb is clickable.
- Left: the sunburst map. Right: the side list. Bottom: the collector bar.
- Window is resizable; the map scales to fit.

### 5.3 Sunburst map
- The centre disc shows the current folder's total size. Each ring outward is one level deeper. A segment's angle is proportional to its size within its parent.
- Shows a fixed number of rings (DaisyDisk shows about 5–6 levels; tune to look right).
- Colour: folders are coloured (each child of the current folder gets a distinct hue; descendants inherit that hue with shifting lightness by depth); **files are grey**. Hidden space is purple. Maclean uses its own palette.
- Children are ordered largest first. Segments too thin to draw are merged per parent into a semi-transparent "smaller objects" segment.
- **Hover** a segment: it highlights, and the side list temporarily shows that segment's name, size and children, so the user can inspect deep items without navigating.
- **Click** a folder segment: navigate into it, with an animated zoom transition. Click the centre disc: go up to the enclosing folder.
- **Right-click** a segment: context menu (§5.6) for that item, even when it is several rings deep.
- Drag a segment onto the collector to collect it.

### 5.4 Side list
- Header: coloured dot, current (or hovered) item name, total size.
- Rows: coloured dot matching the map, name, size, sorted by size descending. The list shows the same children the map shows at ring 1.
- "smaller objects…" row (grey). Clicking it expands the full list of small items inline, scrollable. Go menu › Always Expand "smaller objects" makes that the default.
- At volume root only: "hidden space…" (purple) row, then a divider, then "free space" and "~ free + purgeable" rows.
- Hover highlights the row (and the matching segment). Click navigates into a folder. Right-click opens the context menu. Rows can be dragged to the collector or out to Finder/other apps.
- Markers: items changed since the scan are struck through (checked lazily: `stat` mtime/inode for rows as they become visible; no file watching — *designer's call*); unreadable (restricted) items are purple; hard links get a marker (one for the first link counted, another for the extra links counted as 0).

### 5.5 Navigation
- Back, Forward, Enclosing Folder, Back to Disks and Folders (Go menu, with standard shortcuts: ⌘[, ⌘], ⌘↑, and so on).
- Breadcrumbs collapse middle items when space is tight.

### 5.6 Context menu (map segment or list row)
- Expand "<name>" (folders only: navigate into it)
- Preview (Space): Quick Look
- Show in Finder
- Open in Terminal
- Move "<name>" to Collector (⌘⌫)

### 5.7 Collector (the global list)
- Bar at the bottom of the window. Empty state: a circle with the hint "Drag and drop files here to collect them".
- Items get in by drag-and-drop (from the map, the list, or Finder), by ⌘⌫, by the context menu, or by Action › Move All Items from Current Folder to Collector.
- **Collected items vanish from the map and list immediately, and every ancestor's size shrinks by their size.** This previews the disk after deletion. The map re-lays out with animation.
- Collecting a folder that contains already-collected items absorbs them, so nothing is counted twice. Collecting an item inside a collected folder isn't possible because that item isn't visible.
- The bar shows the running total in the circle and "<size> collected", with a red **Delete** button.
- Clicking the circle expands a panel listing collected items (name, size). Each row has an × to remove it, and a context menu: Preview, Show in Finder, Open in Terminal, Remove "<name>" from Collector (⌘⌫). Removing an item restores it to the map and sizes.
- Action › Remove All Items From Collector.
- The collector is global across navigation within a scan result.

### 5.8 Delete
- Action › Delete Collected Items, or the Delete button.
- DaisyDisk's documented behaviour: pressing Delete starts a **5-second countdown with Cancel**, then deletes **permanently** (no Trash, no undo). When write permission is missing, it asks for admin rights automatically. The map updates without a rescan.
- **Owner's decision: delete permanently, like DaisyDisk**, after the 5-second countdown with Cancel. Settings offers "Move to Trash instead" for users who want undo (off by default). *Designer's call on the setting.* Maclean's safety rules apply on top:
  1. Before deleting each item, re-check that the path still exists and that its inode and device match the scan. For folders, also re-walk the subtree (a fast count/size walk, no tree rebuild) and compare it with the scan. If anything changed, the item isn't deleted silently: the summary lists it as "changed since scan", and the user can confirm deleting it as it is now or skip it. *Designer's call.*
  2. Protected locations are refused **at collect time** (DaisyDisk's way, with a message explaining why) and checked again at delete time. Protected: SIP-protected paths (`/System`, `/usr` except `/usr/local`, `/bin`, `/sbin`, sealed system volume), the Maclean app itself, volume roots, `/Library` *itself* and the home folder *itself* (their contents, such as `/Library/Caches`, remain collectable, as in DaisyDisk), merged "smaller objects" segments, and anything on Time Machine volumes. *Designer's call on the "itself" reading.*
  3. Items needing elevated rights are deleted through the same admin mechanism as §6.5, behind the standard password prompt.
  4. Show progress; allow cancelling between items.
  5. At the end, show a summary: freed size, plus failures with reasons. Failed items stay in the collector. (DaisyDisk's guide doesn't cover partial failure; this is Maclean's design.)
- After deleting, update the tree and the volume's free space. Optional "congratulations after deleting > 5 GB" message (a setting, as in DaisyDisk).

### 5.9 Hidden space
- At volume root, "hidden space…" = volume used space − scanned total. Opening it shows a ring and breakdown rows: **purgeable space**, **snapshots…**, **other volumes**, **still hidden**, with an explanation and **Rescan as Administrator** when restricted folders couldn't be read.
- Purgeable = `volumeAvailableCapacityForImportantUsage` − `volumeAvailableCapacity`. Other volumes = the other APFS volumes in the same container (VM, Preboot, Recovery, …). Snapshots = local APFS snapshots, listed for reference and not added to the total. Still hidden = remainder.
- Dragging **purgeable space** or a **snapshot** to the collector and deleting it forces macOS to purge it. *Designer's call on mechanism:* snapshots are deleted with `tmutil deletelocalsnapshots <date>` through the admin path (§6.5). Purgeable space is forced by writing a temporary fill file in Maclean's own cache folder, which pushes macOS to evict purgeable data, and stopping while at least 2 GB stays free. The fill file is always removed, including after a crash (removed on next launch). Snapshot sizes are shown only where they can be measured with public tools; otherwise "size unknown". This is in the last build phase. That takes 2–10 minutes, and several GB usually remain. The numbers refresh afterwards without a rescan.
- The start-screen gauge redraws with purgeable space counted as used while ⌥ is held.

### 5.10 Permissions, Full Disk Access, admin scan
- Settings › Full Disk Access tab: shows status ("has full access … no further action is required") or a guide plus a button opening System Settings › Privacy & Security › Full Disk Access.
- On first scan without Full Disk Access, prompt with the same guide. The scan can continue in limited mode; unreadable folders count toward hidden space.
- **Rescan as Administrator**, **Quick Rescan as Administrator** (re-scans only the folders that failed for permission reasons), **Rescan as Normal User**. Mechanism in §6.5.

### 5.11 Other actions (Action menu)
Rescan Current Folder, Rescan, Show Current Folder in Finder, Open Current Folder in Terminal, Launch Disk Utility…

### 5.12 Cloud scan
DaisyDisk can scan Dropbox, Google Drive, OneDrive and Box accounts through their web APIs and show them in the same map.
**Owner's decision: later, not in v1.** The only v1 accommodation: tree nodes don't assume a local inode or device (those fields are optional), so a cloud source can fill the same tree later. No provider code, OAuth or abstraction layers in v1.

### 5.12a Further parity items (from the user guide)
The owner wants every DaisyDisk feature, so the research notes govern wherever §5 is silent. In particular:
- **Packages and bundles** (`.app`, `.photoslibrary`, …) appear as single solid items. The context menu adds **Show Package Contents**, which drills inside. The scanner flags package nodes (via `URLResourceKey.isPackageKey` or the bundle bit); the map and list treat them as leaves unless opened.
- **Starred folders**: scanned folders can be starred to stay pinned in the Disks and Folders list.
- Dragging a disk or folder onto the start screen scans it.
- **Network shares** use logical size (physical size isn't reliable there).
- **Get Info** opens the Finder Get Info window for the item (via Finder scripting). *Designer's call* rather than a custom panel.

### 5.13 Settings
- General: Automatically check for updates (checks GitHub Releases' latest tag; no auto-install in v1); Show congratulations after deleting more than 5 GB.
- Full Disk Access tab (§5.10).
- **Maclean addition:** Terminal app picker (Terminal, iTerm, Warp, Ghostty, …) for "Open in Terminal". *Designer's call;* the owner uses Warp.

### 5.14 Menus
Mirror DaisyDisk's menu bar: App (About, Check for Updates…, Settings…, Hide/Quit), Edit, View (Enter Full Screen), Action (§5.11 plus scan/collector items), Go (§5.5), Window, Help (Maclean Help → GitHub README, Report an Issue, Website).

### 5.15 Keyboard and gestures
Most act on the item **under the pointer**, falling back to the selected list item.
- ↑/↓ move through the list; PgUp/PgDn/Home/End jump a page or to the ends
- Return or pinch-open: enter folder. ⌘↑ or pinch-close: enclosing folder
- ⌘[ / ⌘] or swipe: back / forward
- Space: Quick Look. ⌘⌫: move to or from the collector. ⌘-click: Show in Finder
- ⌘R: rescan current folder. ⇧⌘R: rescan disk. ⌥ on admin rescan: full instead of quick

## 6. Architecture

### 6.1 Modules
- `MacleanCore`: a Swift package with no UI. It holds the scanner, tree model, size accounting, collector logic, delete engine, hidden-space calculation and scan-cache serialization. Fully unit-testable with `swift test`.
- `MacleanScan` (CLI): a thin executable that runs the scanner on a path and writes the binary tree format to stdout or a file. Used by the admin scan, and handy for debugging and benchmarking.
- `Maclean.app`: SwiftUI app shell plus AppKit where needed (sunburst `NSView`/`Canvas`, Quick Look panel, drag and drop, menus).

### 6.2 Scanner
- Parallel traversal with a work-stealing pool of directory jobs (about the core count). Each job reads entries in bulk with `getattrlistbulk` (name, type, inode, link count, allocated size, device, flags).
- Size metric: **allocated size on disk** (what is actually freed), not logical size.
- The scan doesn't cross into other disks, disk images or network mounts, but does descend into the other APFS volumes of the root's container (Preboot, VM, Update, Recovery) as DaisyDisk does, skipping /System/Volumes/Data (reached via firmlinks), Preboot's cryptex grafts, and APFS snapshot mounts. On the APFS startup disk, handle the System/Data firmlink layout so nothing is counted twice and the root view looks like Finder's `/`.
- Hard links: count each inode once; later links count as zero. APFS clones: shared blocks count once, the same way (detect with the clone-id attributes available on macOS 14+).
- Several scans may run at once; scans of the same spinning hard disk are queued.
- If a single file system call hangs for more than about 60 s, show a "file system not responding" error for that path and continue.
- Don't follow symlinks; they count as their own tiny size.
- Permission-denied directories are recorded with a "restricted" flag so they feed hidden space and Quick Rescan as Administrator.
- Progress is reported as scanned bytes versus volume used bytes, throttled to UI frame rate. The scan can be cancelled.

### 6.3 Tree model
- Startup disks can hold millions of nodes, so the tree is a compact, index-based struct-of-arrays: parent index, first-child and child-count ranges, size, flags, inode and device, name offset into a shared UTF-8 name buffer. Target (revised in Plan 1b after measuring): steady state at most 40 bytes per node plus name bytes; peak while building at most 100 bytes per node including names (about 1 GB for 10M files).
- After the scan, children are sorted by size, and subtree sizes are summed bottom-up.
- Collector state is a set of node indices. "Effective size" = subtree size − collected descendants. It is updated incrementally along the ancestor path on collect and uncollect.

### 6.4 Scan cache
- Each volume or folder result is stored under `~/Library/Application Support/Maclean/Scans/` in the compact binary format, keyed by volume UUID and path. On start it loads lazily, so "View" opens instantly. "Forget Scan Result" deletes the file.
- Results are snapshots and show their scan time. No live file watching in v1 (DaisyDisk doesn't watch either; Rescan is the refresh).

### 6.5 Admin scan without a signed helper
- The app runs the bundled `MacleanScan` CLI through `osascript` `do shell script "…" with administrator privileges`, which shows the standard macOS password prompt. Output goes to a temp file the app can read, which the app then loads and merges. For Quick Rescan, only the restricted subtrees are re-scanned and spliced in.
- The app passes the CLI path and arguments safely (quoted, no user-controlled shell text).

### 6.6 Delete engine
- Runs off the main thread, item by item, applying the §5.8 checks.
- Permanent deletion (`removeItem`, or `rm`-equivalent in the root step); `trashItem` when the Trash setting is on. Items needing root are deleted through the §6.5 admin path behind the password prompt; the root-run step deletes only the exact paths the app passes, after the same inode checks.
- Returns per-item results; the tree and collector update from them.

### 6.7 Sunburst rendering
- Layout is computed from the current root to N levels deep, merging slices below the minimum angle into "smaller objects".
- Drawn with Core Graphics (or SwiftUI `Canvas`) at 60 fps on ProMotion; hit-testing uses polar coordinates (radius → ring, angle → segment).
- Transitions (drill in/out, collect/uncollect) interpolate segment angles and radii.

## 7. Testing
- `MacleanCore` unit tests on temp-directory fixtures: nested folders, hard links, symlinks, unreadable folders, sparse/clone files, mount boundaries (where feasible), and many-file performance.
- Collector math tests: collect/uncollect/absorb, effective sizes.
- Delete tests in temp dirs only: changed-since-scan, protected paths, Trash, partial failure.
- Benchmark: `MacleanScan` on the real startup disk (read-only) compared with DaisyDisk's ~30 s.
- Manual UI checklist mirroring §5.

## 8. Distribution
- GitHub repo `maclean`, MIT licence, README with screenshots, Gatekeeper "Open Anyway" steps, Full Disk Access steps, and build-from-source (`xcodebuild` / `make`).
- GitHub Actions: build universal, ad-hoc sign, package `.dmg`, attach to the release on tag.

## 9. Suggested build order
1. Core scanner + tree + CLI (benchmark against DaisyDisk).
2. Window: start screen, sunburst, side list, navigation.
3. Collector + delete + context actions (Quick Look, Finder, Terminal).
4. Hidden space, Full Disk Access onboarding, admin scan, scan cache.
5. Settings, menus, shortcuts, polish, release pipeline.
6. Cloud scan: post-v1.

## 10. Left to the builder
- Exact palette, icon, animation curves, ring count, minimum segment angle.
- Xcode project layout and tooling.
- Binary cache format details.

## 11. Open questions
None.
