# Changelog
## 0.4.0 - 2026-11-08

### Features
- Ship a dmg with each release

## 0.3.0 - 2026-11-08

### Features
- Run admin helper in-process with prompt
- Full disk access sheet and prompt coordinator
- Root read mode for restricted folders, tree graft
- Ask for admin password to read restricted items
- Update core versions, signatures, install source
- Auto-update from signed github releases
- Root install-update mode for password updates
- Embed release update key


### Fixes
- Per-invocation exit status in admin batches
- Present prompts app-wide, safe sheet dismissal
- Pin restricted folder before root scan
- Fewer admin prompts, accurate counts
- Homebrew install means /Applications/Maclean.app only
- Same-volume staging and safe rollback for updates
- Refuse downgrades, strip ACLs in root install
- Prompt order, visible sheets, release script checks
- Detect full disk access on macos 27
- Quit & reopen works with the fda sheet up
- Keep privacy-locked folders out of password read
- Skip ~/Library/Photos without full disk access
- Build with older swift on ci

## 0.2.0 - 2026-11-08

### Features
- **core:** Add compact FileTree and builder
- **core:** Add getattrlistbulk directory reader
- **core:** Add parallel scanner with link/clone dedupe
- **core:** Add binary tree archive
- **cli:** Add maclean-scan with summary and archive output
- **core:** Descend same-container APFS volumes like DaisyDisk
- **kit:** Sunburst layout and hit-testing
- **kit:** Palette, size text and navigation history
- **kit:** Volume list filtering and starred folders
- **app:** App target, scan sessions and start screen
- **app:** Main window with ring chart, side list and navigation
- **app:** Actions, context menu, window modes, menus and shortcuts
- **app:** Add app icon
- **app:** Accessibility pass and manual checklist
- **app:** Add Star Folder to Scanned Folders rows
- **kit:** Add TreeView overlay for collected nodes
- **core:** Add collector protection rules
- **core:** Add deleter
- **app:** Add session collector and angle morph
- **app:** Add collector bar, panel and drag and drop
- Add delete flow with admin helper
- Add subtree measurer with timestamps
- Add smart clean protection context
- Add smart clean catalog and engine
- Add live probes and leftover detection
- Find project build leftovers
- Root helper checks smart clean rules
- Add smart clean controller
- Add smart clean card, review and settings
- Add homebrew cask and release packaging


### Fixes
- **core:** Avoid doubled slash in path and test byte-exact names
- **core:** Bounds-check bulk records, follow symlinked scan root
- **core:** Validate archive tree invariants on read
- **cli:** Escape control chars in printed names and paths
- **cli:** Exit 3 on write failure, short errors, TTY-only progress
- **core:** Detect mount points and canonicalize scan root
- **cli:** Reject flag as option value
- **core:** Skip Preboot cryptex grafts to avoid double counting
- **core:** Never descend APFS snapshot mounts
- **core:** Cap single fd grant and raise CLI fd limit
- **core:** Write archive names count little-endian
- **core:** Skip cryptex grafts when scanning Preboot
- **kit:** Guard non-positive rings and harden hit-test
- **kit:** Monotonic palette rings, root-bounded history
- **kit:** Keep offline stars, drop trashed, canonicalize, sort volumes
- **app:** Scanned folders row, scan feedback, off-main fs work
- **app:** Hover highlight on layers, cheap list retarget
- **app:** Context menus, AppKit keyboard focus, menu items, Get Info
- **app:** Keep chart focus after drill, toolbar tab loop, contrast separators
- **core:** Bounds-check NodeChildren subscript
- **app:** Release forgotten results, reuse scan window on View
- **app:** Shrink main window back to start size on Disks
- **app:** Match Action titles to targets, hide Help links
- **core:** Refuse ancestors of app and home
- **app:** Block uncollect during delete
- **app:** Ignore chart hover under collector panel
- Harden delete flow lifecycle and root check
- Escalate restricted folders forced, harden admin
- **admin:** Verify items file hash as root
- Measurer clone dedup and nested age test
- Tighten smart clean protection and corpus test
- Cap size-unknown tier, catalog gaps
- Age gate without measurement, probe hardening
- Harden git probe, deep local-patch check
- Root re-checks launchd orphans, file type
- Root installed set ignores app home
- Bounded no-follow plist reads
- Smart clean alert and card copy, menu feedback
- Admin-only items, no launch prompts, refresh free space


### Performance
- **core:** Permute tree columns in place and drop stored counts
- **core:** Run scan reads off the cooperative pool with shared fd budget

