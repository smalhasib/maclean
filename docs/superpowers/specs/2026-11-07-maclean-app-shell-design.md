# Maclean — Plan 2 Design: App Shell, Ring Chart, Navigation

Date: 2026-11-07
Status: awaiting owner approval
Parent spec: `docs/superpowers/specs/2026-11-07-maclean-design.md` (the product spec, which covers the feature list and safety rules)
Builds on: `MacleanCore` (scanner, `FileTree`, `TreeArchive`, `FDBudget`), merged on `main`. Follow-ups that matter here are listed at the end of `docs/superpowers/plans/2026-11-07-maclean-01b-scanner-followups.md`.

## 1. Intent

Turn the scanner into the app people see and use. The window opens on your disks, scans one, and shows it as a ring chart you can explore by hovering, clicking and keyboard, the way DaisyDisk works, with a **clean, minimal, modern** look of Maclean's own.

**What the owner asked for, in their words:**
- "clean minimal modern ui but the functionalities will be same as daisydisk"
- "support both light and dark mode, also nothing should be too cluttered or congested, everything should be readable, also support keyboard shortcuts"
- Picked the **light & airy** look (mockup A), the **compact disk list** start screen, and **both window behaviours behind a setting**.

Mockups (reference only, not pixel specs): `.superpowers/brainstorm/20561-1794045362/content/{visual-style,start-and-dark,window-flow}.html`. These are git-ignored, so copy any you want to keep into `docs/`.

**Success:** a DaisyDisk user can open Maclean, scan a disk, and explore it without reading anything. It looks calm and uncluttered in both appearances, and every action can be done from the keyboard.

## 2. Scope

### In Plan 2
- The app target, built and bundled **without Xcode**.
- The start screen (disk list, starred folders, Scan Folder…, drag-to-scan).
- Scanning with progress and cancel.
- The main window: breadcrumbs, back/forward, ring chart, side list.
- Hover preview; click to drill in and out; "smaller objects" expansion; packages shown as single items.
- The context menu: Expand, Show Package Contents, Preview (Quick Look), Show in Finder, Open in Terminal, Open in New Window.
- Keyboard shortcuts and menus for all of the above.
- The window-mode setting and a minimal Settings window.
- In-session scan results: a scanned disk shows **View** until the app quits.
- The collector bar's **visual** empty state only.

### Not in Plan 2 (later plans)
- **Plan 3:** collecting and deleting, the collector panel, and "changed since scan" markers.
- **Plan 4:** hidden space, Full Disk Access onboarding, admin scan, persisted scan cache (View across launches), the 60 s not-responding error, and queueing scans per spinning disk.
- **Plan 5:** the terminal picker, check for updates, the congratulations message, the release pipeline and the app icon.

In Plan 2 no menu item or shortcut offers collecting or deleting, not even disabled. Showing them would promise something that doesn't work yet.

## 3. Constraints

- macOS 14+, Swift 6 language mode, SwiftUI with AppKit where SwiftUI falls short. No third-party dependencies.
- **No Xcode.** The owner has Command Line Tools only. The app is a SwiftPM executable target, and a script assembles `Maclean.app` (Info.plist, resources, ad-hoc `codesign -s -`). `swift build` and `swift test` must keep working.
- **Plan 1b prerequisites, delivered as Plan 2's first task:**
  1. The app raises its soft `RLIMIT_NOFILE` to min(hard, 10240) at launch, as `maclean-scan` does.
  2. Add a bulk `FileTree.fileCounts()`, or avoid per-row `fileCount(of:)`, which is O(subtree).
  3. Check `Task.isCancelled` after `finish()`.
  4. Decide the I/O queue's QoS. *Designer's call:* the scan runs at `.userInitiated`, and the I/O queue drops its fixed `.utility` and inherits the submitter's QoS instead.
  5. Give `children(of:)` a non-allocating, range-backed collection, since the chart calls it in hot paths.
  6. Add the `ScanBoundary.forRoot(_:mounts:)` seam (the volume-list tests reuse the fake mount list).
  - Not in Plan 2: early-resuming read continuations. *Designer's call:* a scan stuck on a hung volume can't be cancelled until Plan 4 adds the 60 s not-responding rule. Cancel then shows "Stopping…" and the row stays busy until the read returns.
- Scanning never blocks the main thread, and the UI stays at 60 fps while a scan runs.
- **Memory:** the app holds only `FileTree` plus small view state. Chart layout is computed for the visible rings only, never for the whole tree.

## 4. Look and feel

### 4.1 Overall
- **Light & airy:** white (light) or deep grey `#1c1c1e`-ish (dark) surfaces, hairline separators, generous padding, no gradients, no heavy chrome. Use semantic system colours where they exist (`windowBackground`, `separator`, `labelColor`, `secondaryLabelColor`), so both appearances and Increase Contrast work automatically.
- **Follows the system appearance.** No in-app override in Plan 2. *Designer's call.*
- **Readable:** body text ≥ 13 pt (SF Pro, the system font); sizes use monospaced digits (`.monospacedDigit()`); no truncation of sizes; names truncate in the middle with the full name in a tooltip.
- **Uncluttered:** at most one accent colour on screen besides the chart (the system accent, for primary buttons). Red is reserved for destructive actions (Plan 3's Delete).

### 4.2 Ring chart palette (Maclean's own)
- **Folders:** each child of the current folder gets a hue from a fixed, ordered list of 8 pastel hues (blue, green, orange, purple, pink, teal, yellow, indigo, repeating). Descendants keep their top-level hue and get lighter and less saturated with each ring outward in light mode, darker in dark mode.
- **Files:** neutral grey. **Smaller objects:** a lighter, semi-transparent grey. **Restricted (unreadable) folders:** a muted purple. **Mount points not descended** (other volumes): an outlined grey ring segment.
- **Contrast:** adjacent hues must differ in lightness too, not only hue, so colour-blind users can tell neighbours apart. The builder picks exact values and checks them in both appearances. Thin gaps between segments: 1.5 pt light, 2 pt dark.

### 4.3 Motion
- Drilling in or out: segments sweep and scale to their new angles in about 0.35 s, ease-in-out. Hover highlight: about 0.1 s.
- With **Reduce Motion** on: no sweep, only crossfades.

## 5. Screens

### 5.1 Start screen ("Disks")
- A compact window, about 520 × 300 pt at minimum, growing with the number of rows. The title is "Maclean".
- **Disk rows:** volume icon, name, "494 GB · 77 GB free", a thin usage bar, and a primary button: **Scan**, or **View** when this session already has a result.
  - A small ▾ menu next to the button holds Rescan, Forget Scan Result, Show in Finder and Get Info. Forget only clears the in-memory result in Plan 2.
- **Which volumes** (*designer's call*, for parity with DaisyDisk):
  - **List:** the startup disk, internal and external disks, mounted disk images, and network shares.
  - **Hide:** system volumes (Preboot, VM, Recovery, Update, `/System/Volumes/*`), autofs placeholders, and Time Machine backup disks.
  - **Network shares** are listed but scanned like any folder; their logical-size accounting is Plan 4.
  - **Live updates:** the list refreshes on mount and unmount (`NSWorkspace` notifications).
- **Startup disk row:**
  - Labelled with the volume's name ("Macintosh HD"), and it scans `/`. Plan 1b's boundary rules then include the Data volume through firmlinks and the container's other volumes.
  - Capacity and free figures come from `/`'s `volumeTotalCapacity` and `volumeAvailableCapacityForImportantUsage` (free + purgeable), which report the whole APFS container. These match DaisyDisk's start screen (494 GB, 77 GB).
  - Progress is bytes counted against the container's used bytes.
- **Starred folders** section, under the disks:
  - Folders the user starred, each with Scan or View.
  - Starring: right-click a folder row or a folder in the chart → **Star Folder**, or drag a folder onto the section. Unstar from the row's context menu.
  - Stored in `UserDefaults` as paths, plus bookmark data so moved folders are still found.
- **Scan Folder…** button at the bottom (⌘O): a folder picker. Dropping a folder or disk on the window, or on the Dock icon, scans it.
- **While scanning:** the row's bar becomes a progress bar. The label shows "Scanning… 182 GB", the bytes counted so far. There's no reliable total in advance, so a full disk's progress is measured against used space and other folders show indeterminate progress. **Cancel** replaces Scan. Several scans can run at once, one per row, sharing `FDBudget.shared`.
- **Empty or error states:**
  - A scan that fails to open its root shows an inline message on the row ("Couldn't read this folder"), not a modal dialog.
  - Scanning without Full Disk Access isn't explained yet (that's Plan 4), but the scan still works.

### 5.2 Main window (a scan result)
- **Toolbar (hairline):** back and forward buttons, then breadcrumbs: **Disks** › Macintosh HD › Users › …
  - Each crumb is clickable. "Disks" returns to the start screen in one-window mode, or brings the launcher forward in window-per-scan mode.
  - Middle crumbs collapse into "…" (with a menu of the hidden ones) when space is tight.
- **Left, ring chart:**
  - The centre disc shows the current folder's size (large) and name (small, below).
  - Rings: **up to 5** levels (*designer's call*; DaisyDisk shows about 5–6). Children are ordered largest first, clockwise from 12 o'clock.
  - Segments under about 0.6° are merged per parent into "smaller objects". *Designer's call:* tune it so the chart never shows unreadable slivers.
- **Right, side list (about 280 pt wide):**
  - A header with a coloured dot, name and size.
  - Rows (dot, name, size) for the children, largest first, then a "smaller objects…" row.
  - Volume roots only: a divider, then "free space" and "free + purgeable".
  - The "hidden space…" row comes in Plan 4, so in Plan 2 the volume root's total is just the scanned total.
- **Bottom, collector bar:** in Plan 2, just the empty state: a dashed circle and "Drag files here to collect them" in secondary text. It isn't interactive and no drop is accepted.
- **Minimum size** about 760 × 520 pt. The chart scales with the window, and the list keeps its width.

### 5.3 Interactions
- **Hover a segment:**
  - The segment highlights, and the side list temporarily shows that item (header, plus children if it's a folder). DaisyDisk does the same: the user can look inside deep items without navigating.
  - Leaving the chart restores the list.
  - Hovering a list row highlights its segment.
- **Click:**
  - A folder segment or row drills into that folder, with animation.
  - The centre disc goes to the enclosing folder.
  - A file does nothing beyond selecting it.
  - Clicking "smaller objects" expands that group in the list. In the chart it does nothing beyond hover.
- **Packages** (`.app`, `.photoslibrary`, …): drawn and listed as single solid items, coloured like files. **Show Package Contents** (context menu) drills inside.
- **Context menu**, on a segment (at any depth) or a row:
  - Expand "name" (folders only)
  - Show Package Contents (packages only)
  - Preview (Space)
  - Show in Finder
  - Open in Terminal
  - Open in New Window (folders)
  - Star Folder / Unstar Folder (folders)
- **Quick Look:** `QLPreviewPanel` for the hovered or selected item.
- **Open in Terminal:** opens the folder (for a file, its enclosing folder) in Terminal.app. The picker for other terminals is Plan 5.
- **Selection:** the list has a keyboard selection, separate from hover. Keyboard actions apply to the hovered item when the mouse is over the chart or list, otherwise to the selected row. That's DaisyDisk's rule: under the pointer first.

### 5.4 Window modes (Settings › General)
- **"Open each scan in its own window"**, off by default.
- **Off: one window.** The start screen and a scan result share one window, which resizes smoothly between the compact list and the main window size. "Disks" goes back; the result stays in memory, so View is instant.
- **On: window per scan.** The start screen is a small launcher that stays open. Each Scan or View opens or brings forward that result's own window, so the same path never gets two windows. Windows support native tabbing (Window › Merge All Windows).
- **Both modes:** **Open in New Window** (context menu, or ⌥-click Scan/View or a folder) opens that folder as its own window.
- A setting change applies to the next window opened.
- **Session identity** (*designer's call*):
  - A session is (tree, root node).
  - **Open in New Window** on a folder inside an existing result **reuses that tree**: it's instant, and the window starts at that folder. Its breadcrumbs still reach up to the tree's root.
  - **Scan Folder…** or a starred folder's **Scan** always starts a **fresh scan** of that path, even if a parent was already scanned, because the user asked for current data.
  - "One window per path" is checked against (tree, node).
- **Rescan** (*designer's call*):
  - In Plan 2, ⌘R "Rescan Current Folder" and the ▾ menu's Rescan both rescan **the session's root** in full, producing a new tree.
  - Every window on the old tree moves to the new one, keeping its current folder, back/forward history and selection **by path**. History is stored as paths, not node IDs. Any path that vanished falls back to its nearest surviving ancestor.
  - ⇧⌘R rescans the disk the current result lives on.
  - Rescanning only the current folder and grafting it into the tree arrives in Plan 3, which needs an updatable tree for collect and delete anyway.
- The collector, when it arrives in Plan 3, is **one app-wide list** shown in every window's bar. Plan 2 only reserves the bar.

### 5.5 Settings window
Plan 2 has a General tab only, holding the window-mode toggle. The other tabs and settings arrive with the plans that need them.

## 6. Keyboard and menus

Every action is in the menu bar with its shortcut shown, so it can be found and remapped in System Settings › Keyboard Shortcuts.

| Action | Shortcut |
|---|---|
| Move selection in list | ↑ / ↓; Page Up / Page Down / Home / End |
| Enter folder / Show Package Contents | Return, ⌘↓, or pinch-open |
| Enclosing folder | ⌘↑ or pinch-close |
| Back / Forward | ⌘[ / ⌘] or two-finger swipe |
| Back to Disks | ⇧⌘D *(designer's call)* |
| Preview (Quick Look) | Space |
| Show in Finder | ⌘-click (as DaisyDisk), or ⌥⌘R from the keyboard *(designer's call)* |
| Open in Terminal | ⌥⌘T *(designer's call)* |
| Open in New Window | ⌥-click / ⌘⇧N *(designer's call)* |
| Rescan current folder / rescan disk | ⌘R / ⇧⌘R |
| Scan Folder… | ⌘O |
| Expand "smaller objects" | ⌘E *(designer's call)* |
| Settings | ⌘, |

**Menus:**
- **App:** About, Settings…, Hide/Quit.
- **File:** Scan Folder…, Close Window.
- **Edit:** standard.
- **View:** Enter Full Screen.
- **Go:** Back, Forward, Enclosing Folder, Back to Disks, Expand "smaller objects", Always Expand "smaller objects" (a toggle, persisted).
- **Action:** Rescan Current Folder, Rescan, Show Current Folder in Finder, Open Current Folder in Terminal, Launch Disk Utility…
- **Window:** standard, with tabbing.
- **Help:** Maclean Help (opens the README on GitHub), Report an Issue. The repo has no remote yet, so both URLs come from one constant (`ProjectLinks.repository`), a placeholder until the GitHub repo exists. *Designer's call.*

**Focus:** the list holds keyboard focus by default. Tab moves between the toolbar, the list and the chart. The chart supports arrow-key segment traversal (*designer's call*: ←/→ between siblings, ↑/↓ out and in).

## 7. Accessibility
- **VoiceOver:** list rows read name, size and kind ("Users, folder, 307.6 gigabytes"). The chart is one accessibility element whose children are its first ring's segments, with the same labels. The list is the primary accessible path.
- **Reduce Motion:** see §4.3. **Increase Contrast:** segment gaps and separators thicken, and text uses full-contrast labels.
- Every action is reachable without a mouse (§6).

## 8. Architecture
- **Targets:**
  - `MacleanCore`: existing, unchanged except the §3 prerequisites.
  - **`MacleanKit`** (new library): UI logic with no SwiftUI views, unit-testable with `swift test`. It holds the sunburst layout (rings, angles, merging, hit-testing by polar coordinates), navigation history (back/forward/up), the size formatter, the palette (hue and lightness per node and appearance), the volume list model, and starred-folder storage.
  - **`Maclean`** (new executable): the SwiftUI and AppKit views, windows, menus, Quick Look bridge and settings.
- **Scan state:** one `@MainActor @Observable` model per scan (`ScanSession`) owns the scan `Task`, progress, result tree and navigation history. The app keeps a registry of sessions keyed by canonical path, which gives instant View in this session and one window per path.
- **Rendering:** the builder chooses SwiftUI `Canvas` or an `NSView` with Core Graphics, against these acceptance numbers on the owner's `/` scan (3.9M nodes):
  - hover highlight in under 16 ms;
  - drill-in animation at 60 fps;
  - first chart frame within 100 ms of opening a result.
  Layout covers only the current root's visible rings.
- **Bundling:** `scripts/build-app.sh` runs `swift build -c release`, assembles `.build/Maclean.app` (Info.plist with bundle id `org.maclean.Maclean`, `LSMinimumSystemVersion` 14.0, a placeholder icon), and signs it ad hoc. `swift run Maclean` must also work during development.

## 9. Testing
- **`MacleanKit` unit tests:**
  - layout angles and merging, against a synthetic tree;
  - hit-testing at ring borders and segment edges;
  - navigation history;
  - palette contrast: adjacent hues differ in lightness by at least a set amount in both appearances;
  - volume filtering, from a fake mount list;
  - starred-folder persistence round-trip.
- **Manual UI checklist, run by the owner or by the builder through computer use:**
  - scan `/`;
  - hover, drill in and out, breadcrumbs and back/forward;
  - every shortcut in §6;
  - context menu actions;
  - Quick Look;
  - both window modes;
  - both appearances;
  - Reduce Motion and Increase Contrast;
  - VoiceOver reading the list.
- **Performance check:** the §8 rendering numbers, measured on `/`.
- **Who verifies** (*designer's call*; the owner said the builder may test on their Mac): the builder runs the manual checklist through computer use and reports any step it can't drive. The owner checks the look.
- **Timing harness:** with `MACLEAN_TIMINGS=1` in the environment, the app logs hover, frame and first-frame timings (`os_signpost` plus stderr), so the §8 numbers can be read without Instruments.
- **Full Disk Access during development:** ad-hoc signing changes the signature every build, which drops the Full Disk Access grant. *Designer's call:*
  - Measure performance without Full Disk Access (about 3.7M nodes on `/`), which is close enough.
  - The build script can optionally sign with a local self-signed certificate (`MACLEAN_SIGN_IDENTITY`), so a grant survives rebuilds. The owner creates that certificate once, if they want.

## 10. Left to the builder
Exact colours (within §4.2's rules), spacing values, animation curves, the 0.6° threshold tuning, the Canvas-versus-NSView choice, and the internal file layout of `MacleanKit` and `Maclean`.

## 11. Open questions
None.
