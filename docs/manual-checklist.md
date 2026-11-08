# Maclean manual UI checklist

The manual checks from the app-shell spec (§9), organised by screen. Run each
item in **light and dark mode** unless it says otherwise, and note pass or fail
with a screenshot. Later plans add their own sections here.

Build and launch:

```sh
scripts/build-app.sh
open -a "$PWD/.build/Maclean.app"            # start screen
open -a "$PWD/.build/Maclean.app" /some/dir  # scan a folder directly
```

## Start screen ("Disks")

- [ ] The window is titled "Maclean", at least about 520 × 300 pt, and grows with the number of rows.
- [ ] Disk rows show the volume icon, name, "494 GB · 77 GB free", a thin usage bar, and **Scan** (or **View** once this session has a result).
- [ ] The startup disk is labelled with its volume name ("Macintosh HD"), and its capacity and free figures match DaisyDisk's start screen.
- [ ] Listed: the startup disk, internal and external disks, mounted disk images, network shares. Hidden: Preboot, VM, Recovery, Update, `/System/Volumes/*`, autofs placeholders, Time Machine disks.
- [ ] Mounting or unmounting a disk image updates the list live.
- [ ] The ▾ menu holds Rescan, Show in Finder, Get Info and Forget Scan Result. Forget is disabled with no result.
- [ ] Get Info opens Finder's info window. If Automation is denied, an inline message appears.
- [ ] **Starred** section: star a folder from a row's or segment's context menu, or by dropping a folder on the section. Unstar from the row's context menu. Stars survive a relaunch, and a moved starred folder is still found.
- [ ] **Scan Folder…** (⌘O) opens a folder picker. Dropping a folder on the window, or on the Dock icon, scans it.
- [ ] A folder scanned this session that isn't a disk or a star appears under "Scanned Folders".
- [ ] A vanished path shows an inline "“name” no longer exists" message that goes away after a few seconds.

## Scanning

- [ ] Scan `/`. The row's bar becomes a progress bar and reads "Scanning… 182 GB". Progress for a full disk is measured against used space; other folders show indeterminate progress.
- [ ] **Cancel** replaces Scan and stops the scan ("Stopping…" while it winds down).
- [ ] Several rows can scan at once.
- [ ] A folder that can't be opened shows "Couldn't read this folder" inline on its row, with no modal dialog.
- [ ] Without Full Disk Access the scan still completes.

## Main window

- [ ] Opening a result grows the window smoothly to at least about 760 × 520 pt. The chart scales with the window, and the list keeps its width of about 280 pt.
- [ ] The toolbar has back and forward buttons, then breadcrumbs (**Disks** › Macintosh HD › Users › …). Middle crumbs collapse into "…" with a menu when the window is narrow.
- [ ] The centre disc shows the current folder's size (large) and name (small, truncated in the middle).
- [ ] Rings go up to 5 levels deep, largest child first, clockwise from 12 o'clock. There are no unreadable slivers, because small items merge into "smaller objects".
- [ ] Colours: 8 pastel hues for folders, getting lighter outward (light mode) or darker (dark mode). Files are grey, smaller objects a lighter translucent grey, restricted folders a muted purple, and other volumes an outlined grey segment. Neighbouring hues differ in lightness. The gaps between segments are thin.
- [ ] Side list: a header with a dot, name, kind and size. Then rows (dot, name, size, chevron for folders), largest first, then "smaller objects…". At a volume root a divider follows, then "free space" and "free + purgeable".
- [ ] Sizes use monospaced digits and are never truncated. Long names truncate in the middle, with the full name as a tooltip.
- [ ] The collector bar shows a dashed circle and "Drag files here to collect them". It doesn't accept drops.

## Interactions

- [ ] Hovering a segment highlights it within about 0.1 s, and the side list shows that item (with its children if it's a folder). Leaving the chart restores the list.
- [ ] Hovering a list row highlights its segment, or the "smaller objects" segment it was merged into.
- [ ] Clicking a folder segment or row drills in with a sweep animation of about 0.35 s. Clicking the centre disc goes to the enclosing folder.
- [ ] Clicking a file only selects it.
- [ ] Clicking "smaller objects…" in the list expands the group. Clicking it in the chart does nothing beyond the hover.
- [ ] Packages (`.app`, `.photoslibrary`) are drawn as solid file-coloured items. **Show Package Contents** drills into them.
- [ ] Breadcrumbs: each crumb navigates there. "Disks" returns to the start screen in one-window mode, or brings the launcher forward in window-per-scan mode.
- [ ] Back and forward, the buttons and a two-finger swipe, move through history.
- [ ] Pinch-open enters the item under the pointer. Pinch-close goes to the enclosing folder.
- [ ] Quick Look (Space) previews the hovered item, or the selected one, and follows the keyboard selection while open.
- [ ] Keyboard actions apply to the item under the pointer first, then to the list selection.

## Keyboard (spec §6)

- [ ] ↑ / ↓ move the list selection. Page Up / Page Down / Home / End work too, and the selection scrolls into view.
- [ ] Return or ⌘↓ enters a folder (or Show Package Contents for a package). Pinch-open does the same.
- [ ] ⌘↑ goes to the enclosing folder. Pinch-close does the same.
- [ ] ⌘[ / ⌘] go back and forward. A two-finger swipe does the same.
- [ ] ⇧⌘D goes back to Disks.
- [ ] Space opens and closes Quick Look.
- [ ] ⌘-click shows the item in Finder. ⌥⌘R does the same from the keyboard.
- [ ] ⌥⌘T opens the item in Terminal (the enclosing folder for a file).
- [ ] ⌥-click or ⇧⌘N opens a folder in a new window.
- [ ] ⌘R rescans the current folder (the session's root in Plan 2). ⇧⌘R rescans the disk.
- [ ] ⌘O opens Scan Folder….
- [ ] ⌘E expands or collapses "smaller objects".
- [ ] ⌘, opens Settings.
- [ ] Every action is in the menu bar with its shortcut: App, File, Edit, View, Go (including the persisted Always Expand "smaller objects" toggle), Action (including Launch Disk Utility…), Window and Help.
- [ ] Focus: the list has keyboard focus by default. Tab moves between the toolbar, the list and the chart: each enabled toolbar control in turn (back, forward, Disks, the breadcrumbs), then the list, then the chart, then back to the toolbar. Shift-Tab goes the other way.
- [ ] A focused toolbar control shows an accent outline (a collapsed crumb shows it on "…"). Return or Space activates it, ←/→ step within the toolbar, and Escape returns to the list.
- [ ] In the chart, ←/→ move between siblings, ↓ moves into the first child, and ↑ moves out to the parent. Return enters and Space previews the keyboard-current segment.
- [ ] Chart focus indication: after Tab, the keyboard-current segment gets an accent outline, or a thin accent ring hugs the chart when nothing is selected. There's no outline after a mouse click until an arrow key is pressed. There's never a full-size focus circle.
- [ ] After a keyboard drill from the chart (Return, ⌘↓, ⌘↑, ⌘[ / ⌘]), the outline stays visible once the animation ends. After drilling in it's on the first child. After going up it's on the folder you came from.

## Context menu

On a segment at any depth, and on a list row:

- [ ] Expand "name" (folders only)
- [ ] Show Package Contents (packages only)
- [ ] Preview (Space)
- [ ] Show in Finder
- [ ] Open in Terminal
- [ ] Open in New Window (folders)
- [ ] Star Folder / Unstar Folder (folders)
- [ ] Control-click opens the menu and never drills in.
- [ ] An action on a path that no longer exists shows the inline "no longer exists" banner.

## Window modes (Settings › General)

- [ ] **Off (default), one window:** the start screen and result share one window, which resizes smoothly. "Disks" goes back, and View is instant afterwards.
- [ ] **On, window per scan:** the start screen is a small launcher that stays open. Each Scan or View opens or brings forward that result's own window, so the same path never gets two windows. Window › Merge All Windows tabs them.
- [ ] In both modes, Open in New Window (context menu, ⌥-click Scan/View, or ⌥-click a folder) opens that folder in its own window. Its breadcrumbs reach up to the tree's root.
- [ ] Changing the setting applies to the next window opened.
- [ ] Rescan moves every window on the old tree to the new one, keeping each window's folder, back/forward history and selection. A vanished path falls back to its nearest surviving ancestor.

## Collector and delete

Only ever delete inside a scratch folder you create, and remove it afterwards.

- [ ] 1. Create `~/maclean-scratch` with folders and files, scan it, collect 3 items, press Delete, and let it finish. Check the summary and that Finder confirms they're gone.
- [ ] 2. Press Delete, then Cancel within 5 s. Nothing is deleted.
- [ ] 3. Collect a folder, add a file to it in Finder, then Delete. It appears under "Changed since the scan"; check both Keep and Delete Anyway.
- [ ] 4. `sudo mkdir ~/maclean-scratch/rootdir` with a file inside it (the owner runs this). Collect it and Delete: the password prompt appears. Approve once, and cancel once.
- [ ] 4b. Restricted subfolder: `mkdir ~/maclean-scratch/mixed`, put a file in it, then `sudo mkdir -m 700 ~/maclean-scratch/mixed/rootonly` and `sudo touch ~/maclean-scratch/mixed/rootonly/x` (the owner runs these). Rescan, collect `mixed` and Delete: it is **not** listed as "Changed since the scan"; one password prompt appears and `mixed` is gone afterwards. Repeat and cancel the prompt: `mixed` is left whole (its readable file is still there) and stays collected.
- [ ] 5. Turn on Trash mode, delete a file, and find it in the Trash. The bar reads "Moving … to the Trash in …" during the countdown and "Moving … of … to the Trash…" while it runs. With Trash mode on, recreate `mixed` as in 4b, rescan and collect it: it moves to the Trash (empty the Trash with the owner's consent, or `sudo rm -rf` it there).
- [ ] 6. Delete Collected Items in the Action menu is disabled with an empty collector and during a run.
- [ ] 7. Scan `/`, collect `/Library/Caches/<some folder>`, start Delete, and **Cancel during the countdown**. Only the prompt path is exercised; nothing outside the scratch folder is ever deleted.

## Smart Clean

Use `~/maclean-scratch` or read-only checks only. Never clean real data.

- [ ] 1. Launch the app. The Smart Clean card appears under the disks and finishes ("… can be cleaned" or "Nothing to clean right now") within about 10 s.
- [ ] 2. Review: Safe items are ticked, Review items are unticked, and Info items (such as large data) have no checkbox.
- [ ] 3. With an app open (for example Safari), its cache is listed under Skipped as "… is open", not offered.
- [ ] 4. Create `~/maclean-scratch/proj/package.json` and `~/maclean-scratch/proj/node_modules/x/file` (add `~/maclean-scratch` under Settings › Smart Clean › project folders, or work in a searched folder), then check again. Maclean's age includes ctime, which `touch -t` can't backdate, so a fresh `node_modules` must be listed under Skipped as "Used recently" and not offered. Don't try to backdate it.
- [ ] 5. "Never clean this" on a row hides it and lists it in Settings › Smart Clean. Removing it there brings it back on the next check.
- [ ] 6. "Measure with administrator rights" asks for the password once and fills in the sizes of system items.
- [ ] 7. Cancel that password prompt: the system items simply stay "size unknown".
- [ ] 7b. With only system items ticked (Move to Trash off), Clean, confirm, and cancel the password prompt: nothing is deleted and the summary lists them as "administrator password not given". With Move to Trash on, the confirmation says system items will be skipped and no password prompt appears.
- [ ] 8. ⇧⌘K re-runs the check and shows the start screen with the card.
- [ ] 9. Turn off the launch check in Settings › Smart Clean and relaunch: no check runs until you ask for one. The launch check never shows a password prompt.
- [ ] 10. Untick everything and check that Clean is disabled. Read the confirmation text (permanent or Trash wording, and the administrator note) without confirming, then Cancel.
- [ ] 11. On a user account without Full Disk Access for Maclean and without the Command Line Tools (or Xcode) installed, launch the app and let the check finish: no system dialog appears (no "would like to access files in your Downloads folder", "data from other apps", or "install the command line developer tools" prompt). Downloads, the Trash, Mail attachments and containers are listed under Skipped as "Needs Full Disk Access".

## Access and updates

Needs a real Mac. Use test releases only; never point the updater at your real `/Applications` copy except in the update checks below.

Full Disk Access sheet:
- [ ] Without Full Disk Access, launch the app: the sheet appears on every launch, before anything else.
- [ ] Revoke access for a build that had it, then relaunch: the sheet returns.
- [ ] Grant access in System Settings and choose **Relaunch**: the app restarts and the sheet is gone.

Administrator reads:
- Note: macOS may reuse an administrator authorization for a few minutes, so a second action soon after the first may not show a dialog. Wait a few minutes (or log out and in) before checks that expect a dialog.
- [ ] **Release gate (before merge):** real-dialog check. With the real administrator dialog: delete a root-owned test item (allow, then cancel on a second try), read restricted folders during a scan (allow, then cancel), and confirm that Cancel leaves everything untouched each time.
- [ ] Scan `/` without Full Disk Access: one administrator dialog names Maclean. Cancel it: the folders stay restricted and nothing else breaks.
- [ ] Scan `/` again and allow: restricted folders are measured, and the result says how many folders still need Full Disk Access, with **Grant Access…**.
- [ ] Turn off "Ask for the administrator password to read restricted folders" in Settings: no dialog appears.
- [ ] Smart Clean measures system items automatically on launch and on ⇧⌘K, with one dialog shared with any waiting scan read. Cancelling suppresses it until the next user-initiated check.
- [ ] **Release gate (before merge):** spike (spec §6a.1): record what root reads with and without Full Disk Access, with the dialog run in-process. Try a TCC folder (`~/Library/Mail`, `~/Library/Messages`) and a root-owned folder (`/private/var/root`, `/Library/Application Support/com.apple.TCC`). Note the results in the plan's outcome section.

Updates:
- [ ] Build and release a test 0.3.0 and a test 0.3.1 signed with "Maclean Release" and a separate **test** update key (generated into a scratch folder, with its public key in a local, uncommitted `UpdateKey.swift`). Never sign test builds with the production key. From 0.3.0, Check for Updates… offers 0.3.1 with its notes.
- [ ] Install and Relaunch: 0.3.1 starts, and Full Disk Access is still granted (no sheet).
- [ ] Skip This Version hides that version from the launch check, and Later dismisses until the next check.
- [ ] Tamper with the zip or its `.sig` on a test release: the update is refused with a message.
- [ ] A Homebrew install (`/Applications/Maclean.app` with the Caskroom entry) shows `brew upgrade --cask maclean` and Copy Command instead of Install and Relaunch.
- [ ] Copy Maclean to a root-owned folder (for example `sudo cp -R` into `/Library/Maclean-test/`) and update it: the password dialog says "Maclean needs your password to update itself.", the swap succeeds, and the new bundle is owned by root (or the original owner). Cancel leaves the app untouched and offers Download. This covers the helper's root-only branches (chown, ACL strip, same-volume swap); check that no `.maclean-update-root-*` folder is left behind.
- [ ] A downgrade (an older signed test release) is refused by the root install.
- [ ] App Management (macOS 13+): updating a copy in `/Applications` replaces the bundle. If macOS asks to allow Maclean to update or delete other applications (Privacy & Security › App Management), allow it and check the swap then succeeds; if denied, the update fails with a message and the old copy still runs.
- [ ] An update doesn't start during a delete or a Smart Clean run.
- [ ] "Check for updates automatically" off: no launch check. Check for Updates… still works.

## Settings

- [ ] ⌘, opens Settings with two tabs, General and Smart Clean. General holds "Open each scan in its own window", "Move to Trash instead of deleting permanently" (off by default), "Ask for the administrator password to read restricted folders" and "Check for updates automatically" (both on by default).
- [ ] The toggle persists across relaunches.

## Appearances

- [ ] Light: white surfaces, hairline separators, pastel rings with 1.5 pt gaps.
- [ ] Dark: deep grey surfaces, darker rings outward, 2 pt gaps.
- [ ] Switching appearance while a result is open re-renders the chart and list immediately.
- [ ] Only one accent colour is on screen besides the chart, and no red appears.

## Reduce Motion

Turn on System Settings › Accessibility › Display › Reduce motion.

- [ ] Drilling in and out crossfades with no sweep.
- [ ] The hover highlight appears instantly, with no fade.
- [ ] The window grows to the result size without animation.

## Increase Contrast

Turn on System Settings › Accessibility › Display › Increase contrast. Toggle it with a result open.

- [ ] The chart re-renders at once: stronger, more saturated colours and thicker segment gaps.
- [ ] The centre disc's folder name and the list's secondary text (sizes, kinds, "smaller objects…", free space) use full-contrast labels. So does the start screen's detail and status text.
- [ ] Separators (toolbar, chart and list divider, list header, collector bar, banners, start-screen rows) are thicker and stronger, and the hover outline is more visible.
- [ ] The keyboard focus outline is thicker.

## VoiceOver

Turn VoiceOver on with ⌘F5.

- [ ] List rows read "<name>, <folder|file|package>, <size>", for example "Users, folder, 307.6 gigabytes". The selected row is announced as selected.
- [ ] Activating a row (VO-Space) drills into a folder or selects a file.
- [ ] The list header reads the name, item count and size. "smaller objects…" reads its item count, size and expanded state, and VO-Space toggles it.
- [ ] The chart is one group, "Disk map of <folder>". Its children are the first ring's segments, with the same labels as the rows. VO-Space on a segment opens it. The ring-1 "smaller objects" segment is read but has no press action.
- [ ] The VoiceOver cursor's outline on a segment sits over that segment.
- [ ] Start-screen rows read the name, then the capacity and free space (or the path), then the state ("not scanned", "scanning, 182 gigabytes counted", "scanned, 300 gigabytes", or the error). Scan/View/Cancel and More are separate buttons.
- [ ] Every action can be reached without a mouse (§6).

## Performance

Measure on the owner's `/` scan without Full Disk Access (about 3.7M nodes). Launch with timings on:

```sh
MACLEAN_TIMINGS=1 .build/Maclean.app/Contents/MacOS/Maclean /
```

- [ ] Hover highlight: `hover` is under 16 ms.
- [ ] Drill-in animation: `drillFPS` is about 60, and `frameInterval` is about 16.7 ms.
- [ ] First chart frame: `firstFrame` is within 100 ms of opening the result.
- [ ] The side list's retarget on hover (`listUpdate`) feels instant.
