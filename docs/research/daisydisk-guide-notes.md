# DaisyDisk v4 User Guide: Behavior Notes for Maclean

Research notes paraphrased from DaisyDisk's official v4 user guide (fetched 2026-11-07). Base URL: https://daisydiskapp.com/guide/4/en/
Purpose: reference for feature parity. Maclean uses its own name, branding and wording.

Note on gaps: the guide is high-level. It does **not** specify sunburst depth limits, the exact small-item threshold, the color algorithm, label rules, or the full Get Info field list. Those need our own design (or observation of the real app). Gaps are marked **[not in guide]**.

---

## 1. Disks overview and scanning
Source: https://daisydiskapp.com/guide/4/en/DisksOverview/

- On launch the app lists every mounted volume, startup disk first.
- Each volume has a usage gauge. Green means at least 50% free; red is a strong warning. **[not in guide: exact thresholds between green and red]**
- One number sits under the gauge: free space. Hovering over it also shows used space.
- By default the gauge counts purgeable space as free, matching Finder and Disk Utility. Holding **Option (⌥)** redraws it with purgeable counted as used. Before High Sierra the default was the reverse.
- Used/free figures in the overview update live, so the screen works as a monitor (Tips page).
- Ways to scan:
  - a whole disk: the **Scan** button next to its gauge, or drag the disk from Finder onto the window or the Dock icon.
  - a folder: **Scan Folder…**, or drag the folder in.
- Folder scans finish faster because they cover fewer files.
- Typical timings: SSD takes seconds, HDD about 2 min. Network shares, virtual disks and Time Machine volumes take longer. Time depends on file count and disk type, not capacity.
- **Starred folders:** click a folder's icon to star it. Starred folders stay pinned in the disk list across relaunches.
- Each disk/folder row has a drop-down menu holding Scan as Administrator, Quick Rescan as Administrator, connected cloud accounts and similar items.

## 2. Sunburst map
Source: https://daisydiskapp.com/guide/4/en/UnderstandingSunburst/

- Folders are drawn as colored segments ("petals") and files as grey ones.
- Segment angular width is proportional to size. Segments are pre-sorted by size.
- Items too thin to draw on their own are merged into **semi-transparent consolidated segments**.
- **Hover:** pointing at a folder shows its contents in the sidebar, with no click needed.
- **Click** a segment to drill into it. **Click the center** to go up to the parent.
- Special sidebar items:
  - **"smaller objects"**: a virtual group of many small files. Clicking it expands the full list, which can run to thousands of items.
  - **Struck-out items**: deleted, renamed or moved outside the app since the scan. Many of them mean you should rescan.
  - **Purple items**: restricted. They can't be measured without an admin scan.
  - **"hidden space"**: a virtual item for space that couldn't be reached. It contains purgeable space, other volumes, snapshots and "still hidden".
- **[not in guide]:** depth (ring count), minimum visible angle, color palette and hue assignment, segment labels, animations.
- Packages/bundles show as single solid items, as in Finder. Use **Show Package Content** to expand one (Tips).
- The app updates the map after in-app deletions, but doesn't watch for changes made in Finder or other tools. The user has to rescan (Tips).
- The app reports **physical** size (allocated on disk), not logical size, except on network drives, where it shows logical size (Tips).

## 3. Preview (Quick Look) and the info sidebar
Source: https://daisydiskapp.com/guide/4/en/Previewing/

- The sidebar shows basic info for the hovered or selected item. **[not in guide: exact fields]**
- Point at an item and press **Space**, or right-click → **Preview**, to open the system Quick Look panel. Installed Quick Look plugins work.
- Preview works from the map, the sidebar and the Collector.
- Other context-menu items mentioned across the guide:
  - Move "X" to Collector
  - Preview
  - Show Package Content
  - Show in Finder (also ⌘-click)
  - Forget Scan Results (frees the RAM a scan uses, which can be hundreds of MB)

## 4. Deleting: the Collector (core flow)
Sources: https://daisydiskapp.com/guide/4/en/DeletingFiles/ , https://daisydiskapp.com/guide/4/en/Undelete/ , https://daisydiskapp.com/guide/4/en/TipsAndTricks/ , https://daisydiskapp.com/guide/4/en/WhatToDelete/

- The **Collector** is a staging area along the bottom of the window. Nothing is touched until the user clicks **Delete**.
- Ways to add items:
  - drag a segment ("tear off a petal") onto the Collector
  - context menu → Move "X" to Collector
  - **⌘⌫** while hovering an item. It toggles: the same key also takes an item back out.
- Clicking the collapsed Collector expands it. The expanded Collector behaves like the sidebar list: items can be previewed and dragged out.
- To remove an item from the Collector: drag it out, click the **×** next to its name, or press ⌘⌫.
- **Protected items are refused:** /System, /Library, the current user's home folder and other essential paths. The Collector won't take them and shows a system message explaining why.
- Consolidated (semi-transparent) segments can't be collected. The user has to expand the group and collect individual items.
- **Delete flow:**
  1. Click Delete. A **5-second countdown** starts, with a **Cancel** button.
  2. If not cancelled, the items are **permanently deleted**. They do **not** go to the Trash, so the space really is freed.
  3. Deleted items can't be undeleted. The guide points users to recovery software or professional services and suggests shutting the Mac down right away.
- After an in-app delete the map updates automatically, with no rescan.
- **Permission escalation:** if a delete needs write access the user lacks (for example a protected app in /Applications), the app tries to raise privileges automatically where possible, which prompts for a password (Restricted page).
- **Time-out:** if the file system doesn't respond to a single file for more than 1 minute, during scan or delete, the app shows a "File system not responding" error (see §16).
- **Failure behavior:** **[not in guide]** what happens on a partial failure (which items failed, retry or skip). Maclean has to design this.
- **Free space not appearing after delete:** with Time Machine on, local snapshots still hold the data. Free space stays the same while purgeable/hidden space grows by the same amount. macOS reclaims it later, or the user can force a purge.
- **Hard links:** the space only comes back when the last link is deleted. After an in-app delete the app updates all sibling links and recalculates folder sizes (HardLinks page).
- **Time Machine volumes:** the app can scan them but refuses to delete anything on them (TimeMachine page).
- **Disk images:** deleting files inside a mounted sparse image does not shrink it. The user must run `hdiutil compact` (DiskImages page).
- **Cloud:** deleting a shared item only removes the current user's access. The owner keeps the file (CloudScan page).
- The guide's safety advice for the UI to echo: only delete things you recognize as your own (by location, name or preview). Use app-specific UIs (iTunes/Music, Photos, Steam, Time Machine) for their own libraries. Empty the Trash first. Moving to Trash doesn't free space.
- Virtual items can also go in the Collector:
  - **purgeable space** forces a purge
  - **snapshots**, or a single snapshot, deletes snapshots

## 5. Keyboard shortcuts and gestures (complete list from guide)
Source: https://daisydiskapp.com/guide/4/en/Hotkeys/

| Action | Key | Trackpad gesture |
|---|---|---|
| Previous item in current folder | ↑ | — |
| Next item | ↓ | — |
| One page up | Page Up (Fn+↑) | — |
| One page down | Page Down (Fn+↓) | — |
| First item | Home (Fn+←) | — |
| Last item | End (Fn+→) | — |
| Go to enclosing folder | ⌘↑ | pinch close |
| History back | ⌘[ | — |
| History forward | ⌘] | — |
| Enter hovered folder / expand "smaller objects" | Return | pinch open |
| Quick Look preview of hovered item | Space | — |
| Move hovered item to/from Collector | ⌘⌫ | — |
| Show hovered item in Finder | ⌘-click | — |
| Rescan current folder | ⌘R | — |
| Rescan whole disk (or topmost folder) | ⇧⌘R | — |
| Toggle gauge: purgeable counted as used vs free | ⌥ (hold) | — |

- The guide's own table pairs the Fn+arrow keys with the wrong rows (Fn→ listed for Page Up, and so on). The table above uses the standard macOS mapping.
- Many actions apply to the **pointed (hovered)** item, not only the selected one. This is a key interaction trait to copy.
- There is a browsing history (back/forward) in addition to going up to the parent.
- Clicking the map center also goes up.

## 6. Hidden space
Source: https://daisydiskapp.com/guide/4/en/HiddenSpace/

- **Calculation:** hidden space = volume used space − total size of scanned files. It appears as a virtual item when that remainder is significant. **[not in guide: threshold]**
- Children of hidden space:
  - **purgeable space**: mainly TM local snapshots, plus swap, sleep image and temp files.
  - **other volumes**: other APFS volumes in the same container.
  - **snapshots**: shown for reference only. Not added to the hidden total (see §9).
  - **still hidden**: whatever is left over. Typically other users' home folders, Spotlight index, document versions and file system overhead (2–3 GB is normal on the startup disk), plus space lost to file system errors.
- Ways to reduce it:
  - grant Full Disk Access, relaunch and rescan
  - Scan as Administrator. Some GB will still remain, which is normal.
- Timing quirks:
  - After a delete with TM on, the system takes minutes to update the purgeable figure. Meanwhile hidden space temporarily absorbs the difference.
  - The app refreshes the hidden/purgeable figures **automatically, without a rescan**, once the system updates.
  - The same lag happens after a forced purge, and it is longer if a TM backup is running.
- Third-party snapshots (for example Carbon Copy Cloner) count as "still hidden", not purgeable. Detect them with `tmutil listlocalsnapshots /`. Only the app that created them can delete them.
- Other causes: file system corruption (fix with Disk Utility, Recovery mode, `fsck_apfs` / `fsck_hfs`) and junk left in /Volumes by backup tools.

## 7. Purgeable space
Source: https://daisydiskapp.com/guide/4/en/PurgeableSpace/

- Purgeable space is not literally free, but apps can use it. macOS reclaims it instantly when an app needs more than the current free space.
- It is allowed to grow up to about **80% of capacity** when free space isn't short.
- The system computes it asynchronously. Changes show up seconds to minutes after the action.
- On High Sierra and later with APFS it lies outside any scannable area, even for root. The app only gives a macro-level figure, plus a delete action.
- Before High Sierra, snapshots were visible in `/.MobileBackups` via an admin scan.
- The disk overview counts it as free, like Finder.
- **Forced purge:** drag the purgeable space item to the Collector and delete it.
  - Takes **2–10 minutes**.
  - Allow a couple more minutes for the system to recompute. The item then updates automatically, with no rescan.
  - About **7–10 GB** usually remains, because macOS can't release everything and starts new temp files right away.
- The Mac App Store edition doesn't have forced purge (sandbox).
- How macOS itself shows it:
  - Finder, About This Mac and Disk Utility report "available" = free + purgeable.
  - High Sierra's About This Mac folds purgeable into "System".
  - Sierra showed a separate "Purgeable" category.

## 8. Other volumes (APFS space sharing)
Source: https://daisydiskapp.com/guide/4/en/ReservedSpace/

- An APFS container holds several volumes that share one pool of free space. The startup container includes hidden system volumes.
- Shown as an opaque **"other volumes"** item inside hidden space, typically a few GB. User-created volumes in the same container are included.

## 9. Local snapshots
Sources: https://daisydiskapp.com/guide/4/en/Snapshots/ , https://daisydiskapp.com/guide/4/en/TimeMachine/

- Time Machine takes local snapshots on APFS all-flash volumes (High Sierra and later). Older systems took them on laptop startup disks and HFS+ drives.
- Snapshots can take up to 80% of the disk. They are the cause of "System is huge" in About This Mac.
- Their contents can't be scanned on APFS, even as root. On older systems they lived in `/.MobileBackups`, viewable with an admin scan.
- The app shows a **"snapshots" item under hidden space** with a list of individual snapshots and their **estimated sizes**, and lets the user delete them.
- Size semantics:
  - a snapshot stores only changed blocks, so it starts small and grows as data is changed or deleted.
  - snapshots share blocks, so the size of a group ≠ the sum of the individual sizes.
  - deleting one snapshot can make the others look bigger.
- Because purgeable space already includes snapshots, the snapshots item **does not add to the hidden space total**. Its sizes are for information only.
- Third-party snapshots (for example CCC) are listed too, which makes users aware of them. They aren't purgeable and macOS doesn't remove them. Only the app that created them can delete them.
- macOS policy: snapshots older than **24 h** are removed automatically. Snapshots are kept only on disks with plenty of free space and are pruned oldest-first when space runs low.
- Deleting: drag the snapshots item, a single snapshot, or purgeable space to the Collector.
  - The App Store edition can't estimate sizes. To delete it hands the user a Terminal script to copy, paste and run, followed by a rescan of the snapshot list.
  - The standalone edition deletes directly.
- `tmutil` is the manual alternative.
- **Document Versions** live in `/.DocumentRevisions-V100`. Deleting that folder loses revision history, not the documents. The guide advises against it.

## 10. Restricted folders
Source: https://daisydiskapp.com/guide/4/en/Restricted/

- Folders the app can't read (system folders, other users' homes) show as empty with size zero, and are drawn in **purple**. Their real size goes into hidden space.
- The fix is Scan as Administrator.
- Deleting without write permission: the app tries to raise privileges automatically.

## 11. Full Disk Access (Mojave and later)
Source: https://daisydiskapp.com/guide/4/en/FullDiskAccess/

- Privacy-protected locations (Photos, Contacts, Calendar, and so on) trigger TCC prompts. If the user denies them, those sizes go into hidden space.
- The app reads only metadata (names and sizes), never file contents, but macOS shows the prompts anyway.
- Recommended: grant Full Disk Access.
- Preferences has a **Full Disk Access tab** that shows whether access is granted and gives instructions.
  - It shows a bouncing app icon. Dragging the icon opens System Settings at the FDA pane, and the user drops the app into the list after unlocking.
  - The user then relaunches and rescans, and hidden space should shrink.

## 12. Scan as Administrator
Source: https://daisydiskapp.com/guide/4/en/AdminScan/

- Available from the disk's or folder's drop-down menu. Asks for the admin password and scans as root (like sudo).
- Not available in the App Store edition.
- A normal scan is a little faster and usually enough. Use admin mode when there is a lot of hidden space.
- **Quick Rescan as Administrator** reuses the existing results and fills in only the restricted parts, which saves time. Holding **⌥** turns it into a full admin rescan.
- Works only on **local APFS and HFS+ volumes**.
- An admin scan of a Time Machine volume takes 3–4× longer, so avoid it (TM page).
- Scanning as admin all the time is pointless unless the Mac has several user accounts (Tips).
- **[not in guide: mechanism]** The guide doesn't say how root access works (privileged helper vs. authorization). For Maclean: likely an SMAppService / launchd privileged helper with XPC.

## 13. Parallel scanning
Source: https://daisydiskapp.com/guide/4/en/ParallelScan/

- Several disks and folders can be scanned at the same time.
- The app detects the disk type:
  - For rotational HDDs, concurrent scans of the **same physical disk are queued**, to avoid head thrashing and wear. The UI shows queued scans as waiting.
  - SSDs always scan in parallel.

## 14. Cloud scanning
Source: https://daisydiskapp.com/guide/4/en/CloudScan/

- Supported providers: **Dropbox, Google Drive, Microsoft OneDrive, Box**. The app scans the provider's servers directly through its API, with no local cache.
- Why not scan the local sync folder: the cache takes disk space, selective sync gives incomplete results, and the bundled apps can't handle several accounts.
- Connecting an account: **Connect [Service] Account** in the drop-down of the Scan Folder… button.
  - It opens the provider's OAuth web page, then shows a success message.
  - Done once per account. The account then appears in the disk list.
  - **Several accounts per service** are supported.
- Size semantics: shared items show the **current user's quota use**, not their physical size.
  - Google Drive: only the owner pays quota, so recipients see 0.
  - Dropbox: both the owner and recipients pay.
  - Google Docs files use no Drive quota but do count in Dropbox. Dropbox misreports .gdoc sizes, which can show up as hidden space.
- Deleting a shared item removes only the recipient's access.
- Google Drive files with multiple parents are handled like hard links: counted once.
- **iCloud Drive can't be scanned via its API** (sandboxed). Scan the local iCloud Drive folder with Scan Folder… instead.

## 15. Hard links and APFS clones
Sources: https://daisydiskapp.com/guide/4/en/HardLinks/ , https://daisydiskapp.com/guide/4/en/APFS/ , https://daisydiskapp.com/guide/4/en/FinderMismatch/

- Symlinks count as small files of their own size.
- **Hard links:** the first link found during the scan is the **primary** and gets the real size. Later links are **secondary** and get a **virtual size of 0**. Finder counts each link, which overstates sizes.
- Sidebar hints:
  - primary link: a **white rectangle inside the bullet**.
  - secondary link: a **dark circle inside the bullet**.
- Deleting a link in-app updates its siblings, for example promoting another link to primary, and recalculates sizes. Changes made outside the app need a rescan.
- Space is freed only when the last link goes.
- Examples with many hard links: TM backups, Safari and iTunes caches.
- **APFS clones:** the same rule as hard links. The first full clone counts and later clones get 0 bytes.
  - Partial clones (shared blocks plus unique blocks) can't be accounted for, because macOS has no reliable API for them. The effect on accuracy is negligible.
  - **Clone detection requires macOS 14 Sonoma or later.**
- HFS+ compressed files are counted at their compressed physical size, while Finder shows the uncompressed size. A copy of such a file may use more space, because the copy isn't compressed.

## 16. Time-out error
Source: https://daisydiskapp.com/guide/4/en/TimeoutError/

- Shown as "File system not responding" when a **single file takes more than 1 minute**, during a scan or a delete.
- Local disk: suggests Disk Utility repair.
- Network: try another protocol or scan locally. Some servers (for example FTP) throttle rapid requests.

## 17. Time Machine volumes
Source: https://daisydiskapp.com/guide/4/en/TimeMachine/

- Scanning is allowed. It typically takes 15–40 min, depending on the connection and the number of backups.
- Deleting from TM volumes is **refused**.
- Hard-link dedup keeps per-snapshot sizes realistic.
- Backup folders are named `YYYY-MM-DD-HHMMSS`.
- The guide tells users to remove data with Time Machine's own "Delete All Backups of…" and to add exclusions.

## 18. Disk images, virtual and network disks
Source: https://daisydiskapp.com/guide/4/en/DiskImages/

- A mounted image reports capacity, used and free figures that come from macOS and may be misleading.
- Fixed-size images: the file size is the capacity, whatever they contain.
- Sparse images and bundles:
  - virtual capacity can exceed the host disk.
  - free space is capped at the host's real free space.
  - used = capacity − free, which can give nonsense values.
  - they never shrink on their own; the fix is `hdiutil compact`.
- Some virtual disks misreport too. Finder shows the same numbers.
- **Network shares:** only used size is shown, with no capacity or free figures, and sizes are logical.

## 19. APFS notes
Source: https://daisydiskapp.com/guide/4/en/APFS/

- Local snapshots are hourly and are the main part of purgeable space. They pile up to 80% and are auto-deleted after 24 h. An admin scan can't reveal them; the app gives macro-level tools instead.
- Space sharing produces the "other volumes" item.
- Clones are handled like hard links.
- APFS scans are slower and use more CPU than HFS+.

## 20. Locating space wasters (content guidance)
Source: https://daisydiskapp.com/guide/4/en/LocatingSpaceWasters/

- Typical large locations to point users to:
  - iOS backups in `~/Library/Application Support/MobileSync/Backup`
  - `~/Movies`, `~/Music`, `~/Downloads`
  - games in `/Applications` and `~/Library/Application Support/Steam`
  - app caches in `~/Library/Application Support` (care needed)
- Use each app's own UI for iTunes/Music and Steam content, to avoid broken library links.
- Purgeable space can be force-reclaimed by dragging it to the Collector.

## 21. Tips page extras
Source: https://daisydiskapp.com/guide/4/en/TipsAndTricks/

- Anything visible in Finder can be scanned.
- Drag and drop is supported everywhere: disks and folders onto the window, items onto the Collector.
- Scan results use RAM (hundreds of MB). **Forget Scan Results** releases it.
- "hidden space" and "smaller objects" are virtual items and behave differently from real files.

---

## Edition differences noted (App Store vs standalone)
- App Store edition lacks:
  - Scan as Administrator
  - forced purge of purgeable space
  - snapshot size estimates
  - direct snapshot deletion (it gives a Terminal script instead)
- Maclean, as an open-source non-App-Store app, can aim for standalone parity.
