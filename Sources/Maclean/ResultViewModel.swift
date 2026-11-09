import Foundation
import MacleanCore
import MacleanKit
import Observation

/// State of one result window: where it is in the tree (history of paths),
/// the chart layout for that folder, and hover/selection. Visible structure
/// (sizes, children, what can be selected) is read through the session's
/// collector overlay (`view`); `tree` is used for names, paths and flags.
@MainActor @Observable final class ResultViewModel {
    /// Where the current hover comes from. A hover from the chart retargets
    /// the side list (look inside without navigating); a hover from the list
    /// only highlights the segment, so the list never changes under the pointer.
    enum HoverSource { case chart, list }

    static let alwaysExpandKey = "AlwaysExpandSmallerObjects"
    /// Children below this share of their parent are "smaller objects" in the
    /// list, matching the chart's 0.6° merge threshold at the root.
    static let smallShare = SunburstLayout.minAngle / (2 * .pi)
    /// Expanded "smaller objects" rows shown at most (a cache folder can hold 100k files).
    static let expandedRowLimit = 2000

    let session: ScanSession
    let tree: FileTree
    /// Finder's name for the scan root ("Macintosh HD" for `/`).
    let rootName: String

    var history: NavigationHistory {
        didSet {
            if ownsSessionHistory { session.history = history }
            syncToHistory()
        }
    }
    private(set) var currentNode: NodeID
    /// Recomputed on navigation and when the session's overlay changes.
    private(set) var layout: SunburstLayout
    /// Bumped whenever `layout` is replaced (drives the chart's transition).
    private(set) var layoutGeneration = 0
    /// Why `layout` last changed: the chart zooms for a navigation and morphs
    /// angles for an overlay change (collect, uncollect, delete).
    enum LayoutChange { case navigation, overlay }
    private(set) var layoutChange = LayoutChange.navigation

    var hovered: NodeID?
    private(set) var hoverSource: HoverSource = .chart
    /// The parent of the chart's "smaller objects" segment under the pointer.
    private(set) var hoveredSmallerObjects: NodeID?
    var selected: NodeID?
    /// The list target whose "smaller objects" row was clicked open.
    var expandedTarget: NodeID?
    /// The toolbar control holding the keyboard focus (Tab cycle: toolbar →
    /// list → chart); nil when the list or chart has it.
    var toolbarFocus: ToolbarItem?

    /// `collector` is the collector bar's circle (first in the cycle, so Tab
    /// from the chart reaches it before the toolbar); enabled while it holds items.
    enum ToolbarItem: Hashable { case collector, back, forward, disks, crumb(String) }

    /// Whether the collector panel is open over the chart (this window only).
    var collectorPanelOpen = false {
        didSet {
            if !collectorPanelOpen {
                panelHovered = nil
                pointerInPanel = false
            }
        }
    }
    /// The collector panel row under the pointer (the action target while
    /// the panel is open: Space previews it, ⌘⌫ removes it).
    var panelHovered: NodeID?
    /// Whether the pointer is over the collector panel. The chart under the
    /// panel keeps reporting hovers; they are ignored meanwhile, so no action
    /// lands on a segment hidden by the panel.
    var pointerInPanel = false {
        didSet {
            guard pointerInPanel, !oldValue else { return }
            hoveredSmallerObjects = nil
            if hoverSource == .chart { hovered = nil }
        }
    }

    var expandSmallerObjects: Bool {
        didSet { defaults.set(expandSmallerObjects, forKey: Self.alwaysExpandKey) }
    }

    /// An inline message ("… no longer exists"); `id` restarts its dismiss timer.
    struct Notice: Equatable {
        let id = UUID()
        let text: String
    }
    private(set) var notice: Notice?
    /// Why the last collect was refused (shown by the collector bar).
    private(set) var collectorRefusal: Notice?

    static let smallerObjectsRefusal = "“smaller objects” is a group. Expand it and collect the items inside."

    /// Volume roots only: (free, free including purgeable) bytes.
    private(set) var volumeSpace: (free: Int64, freePurgeable: Int64)?

    /// What the side list shows: the chart-hovered item, else the current folder.
    var listTarget: NodeID {
        if hoverSource == .chart, let hovered { return hovered }
        return currentNode
    }

    /// What keyboard actions apply to: under the pointer first, else the selection.
    /// With the collector panel open, the panel row under the pointer comes first.
    var actionTarget: NodeID? {
        if collectorPanelOpen, let row = panelHovered { return row }
        return hovered ?? selected
    }

    /// The session's overlay on this tree. While the session rescans (or
    /// after a failed rescan) it has none for this tree, so the last one seen
    /// is used and the window keeps showing what it showed.
    var view: TreeView {
        if let v = session.view, v.tree === tree { return v }
        return lastView
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// Whether navigation is written back to `session.history` (the main
    /// window's result, so View returns to where it was). Other windows on
    /// the session keep their own history.
    @ObservationIgnored private let ownsSessionHistory: Bool
    @ObservationIgnored private var currentPath: String
    /// The overlay `layout` was built from.
    @ObservationIgnored private var lastView: TreeView
    /// Set by `open(_:)` so the history change doesn't re-resolve the path.
    @ObservationIgnored private var pendingNode: NodeID?
    @ObservationIgnored private var segmentIndex: [NodeID: Int] = [:]
    /// Parent → index of its merged "smaller objects" segment.
    @ObservationIgnored private var smallerIndex: [NodeID: Int] = [:]
    /// The folder shown before the last navigation (keyboard focus after going up).
    @ObservationIgnored private var previousFolder: NodeID?
    @ObservationIgnored let openedAt = Timings.now
    @ObservationIgnored private var firstFrameReported = false

    /// `history` defaults to the session's; `startPath` is then visited.
    /// `selectedPath` restores a selection by path (after a rescan).
    init(session: ScanSession, startPath: String? = nil, history start: NavigationHistory? = nil,
         selectedPath: String? = nil, ownsSessionHistory: Bool = true, defaults: UserDefaults = .standard) {
        guard let tree = session.tree else { preconditionFailure("ResultViewModel needs a finished scan") }
        self.session = session
        self.tree = tree
        self.defaults = defaults
        self.ownsSessionHistory = ownsSessionHistory
        expandSmallerObjects = defaults.bool(forKey: Self.alwaysExpandKey)
        let name = FileManager.default.displayName(atPath: tree.rootPath)
        rootName = name.isEmpty ? tree.rootPath : name

        let view = session.view.flatMap { $0.tree === tree ? $0 : nil } ?? TreeView(tree: tree)
        lastView = view
        var history = start ?? session.history
        if let startPath { history.visit(startPath) }
        let node = Self.visibleNode(atPath: history.current, in: view)
        if node == nil { history = NavigationHistory(rootPath: tree.rootPath) }
        self.history = history
        currentNode = node ?? tree.root
        currentPath = history.current
        layout = Self.computeLayout(view: view, root: node ?? tree.root)
        rebuildSegmentIndex()
        if let selectedPath, let node = Self.visibleNode(atPath: selectedPath, in: view), node != currentNode {
            selected = node
        }
        refreshVolumeSpace()
    }

    /// A model for `tree` (a rescan of `old`'s session) that keeps `old`'s
    /// current folder, back/forward history and selection by path; vanished
    /// paths fall back to their nearest surviving ancestor.
    convenience init(remapping old: ResultViewModel, to tree: FileTree, ownsSessionHistory: Bool) {
        var history = old.history
        history.remap { tree.node(atPath: $0) != nil }
        self.init(session: old.session, history: history, selectedPath: old.selected.map { old.tree.path(of: $0) },
                  ownsSessionHistory: ownsSessionHistory, defaults: old.defaults)
        // A rescan or the password read swaps the window's model mid-walkthrough: it carries on.
        guideStep = old.guideStep
    }

    // MARK: Graph guide

    /// The step of the chart walkthrough on screen; nil when it isn't showing.
    private(set) var guideStep: Int?

    /// Shows the walkthrough the first time a result is opened. It counts as seen as soon as it shows.
    func showGuideIfFirstTime() {
        guard !defaults.bool(forKey: GraphGuide.seenKey) else { return }
        startGuide()
    }

    /// Help › Show Graph Guide, and the first-time start.
    func startGuide() {
        defaults.set(true, forKey: GraphGuide.seenKey)
        guideStep = 0
    }

    func guideNext() {
        guard let step = guideStep else { return }
        guideStep = step + 1 < GraphGuide.steps.count ? step + 1 : nil
    }

    func guideBack() {
        if let step = guideStep, step > 0 { guideStep = step - 1 }
    }

    func endGuide() { guideStep = nil }

    // MARK: Navigation

    /// Drills into a folder (or a package, for Show Package Contents).
    func open(_ node: NodeID) {
        guard tree.flags(of: node).contains(.directory), node != currentNode, !view.isHidden(node) else { return }
        pendingNode = node
        history.visit(tree.path(of: node))
    }

    /// A click or VoiceOver activation on an item: drill into a folder, else select it.
    func activate(_ node: NodeID) {
        if isDrillable(node) { open(node) } else { selected = node }
    }

    func goUp() {
        guard let parent = tree.parent(of: currentNode) else { return }
        open(parent)
    }

    func back() { history.back() }
    func forward() { history.forward() }

    /// Goes to an absolute path inside the tree (breadcrumbs).
    func visit(path: String) { history.visit(path) }

    // MARK: Selection (keyboard)

    enum SelectionMove { case up, down, pageUp, pageDown, home, end }
    enum Traversal { case previous, next, out, into }

    static let pageStep = 10

    /// Rows the list shows for the current folder: its visible children,
    /// plus the expanded "smaller objects" (capped like the list).
    var listRowCount: Int {
        let kids = view.children(of: currentNode).count
        let visible = visibleChildCount(of: currentNode)
        guard isExpanded(currentNode) else { return visible }
        return min(kids, visible + Self.expandedRowLimit)
    }

    /// The selection's row in the current folder's list, if it is one.
    var selectedRow: Int? {
        guard let selected, tree.parent(of: selected) == currentNode else { return nil }
        guard let i = view.children(of: currentNode).firstIndex(of: selected), i < listRowCount else { return nil }
        return i
    }

    /// ↑/↓, Page Up/Down, Home/End in the list.
    func moveSelection(_ move: SelectionMove) {
        let count = listRowCount
        guard count > 0 else { return }
        let row = selectedRow
        let target: Int
        switch move {
        case .down: target = row.map { $0 + 1 } ?? 0
        case .up: target = row.map { $0 - 1 } ?? count - 1
        case .pageDown: target = (row ?? -1) + Self.pageStep
        case .pageUp: target = (row ?? count) - Self.pageStep
        case .home: target = 0
        case .end: target = count - 1
        }
        selected = view.children(of: currentNode)[min(max(target, 0), count - 1)]
    }

    /// Arrow keys in the chart: ←/→ between siblings, ↑ out, ↓ in.
    func traverse(_ step: Traversal) {
        let view = self.view
        guard let selected, selected != currentNode, isInside(selected), !view.isHidden(selected) else {
            let kids = view.children(of: currentNode)
            if visibleChildCount(of: currentNode) > 0 { self.selected = kids[0] }
            return
        }
        switch step {
        case .previous, .next:
            guard let parent = tree.parent(of: selected) else { return }
            let kids = view.children(of: parent)
            guard let i = kids.firstIndex(of: selected) else { return }
            let count = max(visibleChildCount(of: parent), i + 1)
            let j = min(max(i + (step == .next ? 1 : -1), 0), count - 1)
            self.selected = kids[j]
        case .out:
            if let parent = tree.parent(of: selected), parent != currentNode { self.selected = parent }
        case .into:
            if tree.flags(of: selected).contains(.directory), visibleChildCount(of: selected) > 0 {
                self.selected = view.children(of: selected)[0]
            }
        }
    }

    /// A selection for the chart's keyboard focus after a navigation: kept if
    /// it is inside the current folder; after going up, the folder the user
    /// came from (its ancestor among the current children); else the first child.
    func selectForKeyboardFocus() {
        let view = self.view
        if let selected, selected != currentNode, isInside(selected), !view.isHidden(selected) { return }
        if var node = previousFolder, node != currentNode, isInside(node), !view.isHidden(node) {
            while let parent = tree.parent(of: node), parent != currentNode { node = parent }
            selected = node
        } else if visibleChildCount(of: currentNode) > 0 {
            selected = view.children(of: currentNode)[0]
        }
    }

    // MARK: Toolbar focus

    /// Breadcrumbs: (name, path) from the scan root to the current folder.
    var crumbs: [(name: String, path: String)] {
        let root = tree.rootPath
        let current = history.current
        var out = [(name: rootName, path: root)]
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard current != root, current.hasPrefix(prefix) else { return out }
        var path = root
        for component in current.dropFirst(prefix.count).split(separator: "/") {
            path = path.hasSuffix("/") ? path + component : path + "/" + component
            out.append((name: String(component), path: path))
        }
        return out
    }

    /// Toolbar controls in Tab order (disabled ones included).
    var toolbarItems: [ToolbarItem] { [.collector, .back, .forward, .disks] + crumbs.map { .crumb($0.path) } }

    func isEnabled(_ item: ToolbarItem) -> Bool {
        switch item {
        case .collector: return !view.collected.isEmpty
        case .back: return history.canGoBack
        case .forward: return history.canGoForward
        case .disks, .crumb: return true
        }
    }

    /// The next (or previous) enabled toolbar control after `item`; nil past the end.
    func toolbarItem(after item: ToolbarItem?, backwards: Bool) -> ToolbarItem? {
        let items = toolbarItems
        var order = Array(items.indices)
        if backwards { order.reverse() }
        let start = item.flatMap { items.firstIndex(of: $0) }
            ?? (item == nil ? nil : items.firstIndex(of: .disks))
        let rest = start.map { s in order.drop { $0 != s }.dropFirst() } ?? order[...]
        return rest.map { items[$0] }.first(where: isEnabled)
    }

    /// Whether `node` lies below the current folder.
    private func isInside(_ node: NodeID) -> Bool {
        var n: NodeID? = node
        while let current = n {
            if current == currentNode { return true }
            n = tree.parent(of: current)
        }
        return false
    }

    /// ⌘E: expands (or collapses) "smaller objects" of what the list shows.
    func toggleSmallerObjects() {
        let target = listTarget
        expandedTarget = expandedTarget == target ? nil : target
    }

    /// Whether the list target has a "smaller objects" row.
    var hasSmallerObjects: Bool {
        visibleChildCount(of: listTarget) < view.children(of: listTarget).count
    }

    // MARK: Notices

    func reportMissing(_ node: NodeID) {
        notice = Notice(text: "“\(name(of: node))” no longer exists")
    }

    func dismissNotice(_ id: UUID? = nil) {
        if id == nil || notice?.id == id { notice = nil }
    }

    func dismissCollectorRefusal(_ id: UUID? = nil) {
        if id == nil || collectorRefusal?.id == id { collectorRefusal = nil }
    }

    /// Shows the session's "collected items no longer exist" note after a
    /// rescan, once (the first window to show it clears it).
    func showCarryOverNote() {
        guard let dropped = session.carryOverDropped else { return }
        session.clearCarryOverDropped()
        notice = Notice(text: dropped == 1
            ? "1 collected item no longer exists and was removed from the collector"
            : "\(dropped.formatted()) collected items no longer exist and were removed from the collector")
    }

    // MARK: Collector

    /// ⌘⌫: toggles the action target (hovered, else selected) in the
    /// collector; never the current folder. Over a "smaller objects" segment
    /// it refuses instead.
    func toggleCollected() {
        guard !session.isDeleting else { return }
        if collectorPanelOpen, let row = panelHovered {
            session.uncollect([row])
            return
        }
        if hovered == nil, hoveredSmallerObjects != nil {
            collectorRefusal = Notice(text: Self.smallerObjectsRefusal)
            return
        }
        guard let target = actionTarget else { return }
        toggleCollected(target)
    }

    /// Collects `id` if it is visible, else puts it back if it is collected.
    /// A refusal is reported through `collectorRefusal`. A no-op while a
    /// delete is running.
    func toggleCollected(_ id: NodeID) {
        guard !session.isDeleting else { return }
        let view = self.view
        if view.collected.contains(id) {
            session.uncollect([id])
        } else if !view.isHidden(id) {
            if let refusal = session.collect([id]).first {
                collectorRefusal = Notice(text: refusal.1.message(name: name(of: refusal.0)))
            }
        }
    }

    /// Collects `ids` (context menu, drops, Move All); the first refusal is
    /// reported through `collectorRefusal`.
    func collect(_ ids: [NodeID]) {
        guard !session.isDeleting else { return }
        if let refusal = session.collect(ids).first {
            collectorRefusal = Notice(text: refusal.1.message(name: name(of: refusal.0)))
        }
    }

    /// Delete from the item's row: asks for confirmation, then deletes just that item. A
    /// protected item is refused with the same message as the collector's.
    func delete(_ node: NodeID) {
        if let refusal = session.deletion.requestDelete(item: node) {
            collectorRefusal = Notice(text: refusal.message(name: name(of: node)))
        }
    }

    /// Action › Move All Items from Current Folder to Collector.
    func collectAllInCurrentFolder() {
        collect(Array(view.children(of: currentNode)))
    }

    /// Message for a Finder drop outside the scan (or of a hidden item).
    static func notInScanRefusal(name: String) -> String { "“\(name)” isn't in this scan." }

    /// The visible node for a path dropped from Finder: the parent folder is
    /// canonicalized (`realpath`) and the last component kept, so a dropped
    /// symlink is the link itself. nil when outside the scan or hidden.
    func visibleNode(forDroppedPath path: String) -> NodeID? {
        let standard = (path as NSString).standardizingPath
        var resolved = standard
        if standard != "/" {
            let parent = (standard as NSString).deletingLastPathComponent
            let canonicalParent = ScanBoundary.canonicalPath(parent) ?? parent
            resolved = (canonicalParent as NSString).appendingPathComponent((standard as NSString).lastPathComponent)
        }
        guard let node = tree.node(atPath: resolved), !view.isHidden(node) else { return nil }
        return node
    }

    /// Collects files dropped from Finder. A path outside the scan, or
    /// already hidden, is refused with "“<name>” isn't in this scan."
    func collectDropped(paths: [String]) {
        guard !session.isDeleting, !paths.isEmpty else { return }
        var ids: [NodeID] = []
        var missing: String?
        for path in paths {
            if let node = visibleNode(forDroppedPath: path) {
                ids.append(node)
            } else if missing == nil {
                missing = (path as NSString).lastPathComponent
            }
        }
        collect(ids)
        if let missing { collectorRefusal = Notice(text: Self.notInScanRefusal(name: missing)) }
    }

    /// The node an in-app drag payload refers to, if it is from this session.
    func node(for payload: NodeDragPayload) -> NodeID? {
        guard payload.sessionID == session.id else { return nil }
        return tree.node(atPath: payload.path)
    }

    /// Whether a drag payload can be collected here (from this session, visible).
    func canCollect(_ payload: NodeDragPayload) -> Bool {
        guard let node = node(for: payload) else { return false }
        return node != tree.root && !view.isHidden(node)
    }

    /// Whether a drag payload is a collected item of this session (a panel row).
    func isCollected(_ payload: NodeDragPayload) -> Bool {
        guard let node = node(for: payload) else { return false }
        return view.collected.contains(node)
    }

    /// Payload for dragging `node` out of this window.
    func dragPayload(for node: NodeID) -> NodeDragPayload {
        NodeDragPayload(sessionID: session.id, path: tree.path(of: node))
    }

    /// The session's overlay changed (called on each `session.view`
    /// generation change): re-lays out the same folder, or, if the current
    /// folder is now hidden, goes to its nearest visible ancestor. Hover,
    /// selection and expansion on hidden items are dropped.
    func viewDidChange() {
        let view = self.view
        guard view.generation != lastView.generation || view.tree !== lastView.tree else { return }
        lastView = view
        if view.isHidden(currentNode) {
            // A visit (not a replace), so Back returns once it's uncollected;
            // didSet → syncToHistory navigates.
            history.visit(nearestSurvivingAncestor(of: tree.path(of: currentNode)))
            return
        }
        hoveredSmallerObjects = nil
        if let p = panelHovered, !view.collected.contains(p) { panelHovered = nil }
        if view.collected.isEmpty {
            collectorPanelOpen = false
            if toolbarFocus == .collector { toolbarFocus = nil }
        }
        if let h = hovered, view.isHidden(h) { hovered = nil }
        if let s = selected, view.isHidden(s) { selected = nil }
        if let e = expandedTarget, view.isHidden(e) { expandedTarget = nil }
        if let p = previousFolder, view.isHidden(p) { previousFolder = nil }
        layout = Self.computeLayout(view: view, root: currentNode)
        layoutChange = .overlay
        layoutGeneration += 1
        rebuildSegmentIndex()
    }

    // MARK: Hover

    /// `smallerObjectsOf`: the parent of the "smaller objects" chart segment
    /// under the pointer (with a nil `node`).
    func hover(_ node: NodeID?, from source: HoverSource, smallerObjectsOf group: NodeID? = nil) {
        // The chart reports segments under the collector panel; ignore them.
        if source == .chart, pointerInPanel { return }
        if source == .chart, hoveredSmallerObjects != group { hoveredSmallerObjects = group }
        if node == nil {
            // Only clear a hover this source owns.
            guard hoverSource == source else { return }
        }
        let retargets = source == .chart && (hovered != node || hoverSource != source)
        let start = Timings.now
        if hovered != node { hovered = node }
        if hoverSource != source { hoverSource = source }
        // The side list follows chart hovers; time its update through the commit.
        if retargets { Timings.markAtNextCommit("listUpdate", since: start) }
    }

    // MARK: Queries for the views

    /// Display name: Finder's volume name for the scan root.
    func name(of node: NodeID) -> String {
        node == tree.root ? rootName : tree.name(of: node)
    }

    func kind(of node: NodeID) -> SegmentKind {
        SegmentKind(flags: tree.flags(of: node))
    }

    /// Spoken kind of an item: "folder", "file" or "package".
    static func kindWord(_ kind: SegmentKind) -> String {
        switch kind {
        case .file: return "file"
        case .package: return "package"
        case .folder, .restricted, .mountPoint, .smallerObjects: return "folder"
        }
    }

    /// VoiceOver label of a list row or chart segment: "Users, folder, 307.6 gigabytes".
    func accessibilityLabel(of node: NodeID) -> String {
        "\(name(of: node)), \(Self.kindWord(kind(of: node))), \(SizeText.spoken(view.size(of: node)))"
    }

    /// Whether clicking drills in (plain folders only; packages open via Show Package Contents).
    func isDrillable(_ node: NodeID) -> Bool { kind(of: node) == .folder }

    /// The chart segment drawn for `node`, if visible.
    func segment(for node: NodeID) -> Segment? {
        segmentIndex[node].map { layout.segments[$0] }
    }

    /// Chart segment index to highlight for a list row: the item's own
    /// segment, else the "smaller objects" segment it was merged into.
    func chartIndex(forListItem node: NodeID) -> Int? {
        if let i = segmentIndex[node] { return i }
        return tree.parent(of: node).flatMap { smallerIndex[$0] }
    }

    /// Palette inputs for `child` (index `index` among `parent`'s children), as
    /// the chart colours it or would one ring further out.
    func colorInputs(child: NodeID, index: Int, parent: NodeID) -> (kind: SegmentKind, top: Int, ring: Int) {
        if let s = segment(for: child) { return (s.kind, s.topLevelIndex, s.ring) }
        if parent != currentNode, let p = segment(for: parent) {
            return (kind(of: child), p.topLevelIndex, p.ring + 1)
        }
        return (kind(of: child), index, 1)
    }

    /// How many leading children of `node` get their own list row (the rest
    /// are "smaller objects"). Children are sorted by size, largest first.
    func visibleChildCount(of node: NodeID) -> Int {
        let view = self.view
        let kids = view.children(of: node)
        let total = view.size(of: node)
        guard total > 0 else { return 0 }
        let cutoff = Double(total) * Self.smallShare
        var lo = 0, hi = kids.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let size = view.size(of: kids[mid])
            if size > 0 && Double(size) >= cutoff { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    func isExpanded(_ target: NodeID) -> Bool { expandSmallerObjects || expandedTarget == target }

    /// Called by the chart after its first frame.
    func chartDidDrawFirstFrame() {
        guard !firstFrameReported else { return }
        firstFrameReported = true
        Timings.mark("firstFrame", (Timings.now - openedAt) * 1000)
    }

    // MARK: Private

    private func syncToHistory() {
        var path = history.current
        let node: NodeID
        if let pending = pendingNode {
            node = pending
        } else if let found = Self.visibleNode(atPath: path, in: view) {
            node = found
        } else {
            // The folder vanished (or was collected): fall back to its nearest
            // surviving ancestor (assigning inside didSet doesn't re-enter it).
            path = nearestSurvivingAncestor(of: path)
            history.replaceCurrent(path)
            if ownsSessionHistory { session.history = history }
            node = tree.node(atPath: path) ?? tree.root
        }
        pendingNode = nil
        guard path != currentPath else { return }
        currentPath = path
        previousFolder = currentNode
        currentNode = node
        hovered = nil
        hoveredSmallerObjects = nil
        hoverSource = .chart
        selected = nil
        expandedTarget = nil
        lastView = view
        layout = Self.computeLayout(view: lastView, root: node)
        layoutChange = .navigation
        layoutGeneration += 1
        rebuildSegmentIndex()
    }

    /// The nearest ancestor of `path` (or `path` itself) that exists and is visible.
    private func nearestSurvivingAncestor(of path: String) -> String {
        let view = self.view
        var path = path
        while path != tree.rootPath, Self.visibleNode(atPath: path, in: view) == nil {
            let parent = (path as NSString).deletingLastPathComponent
            path = PathUtil.isInside(parent, orEqualTo: tree.rootPath) ? parent : tree.rootPath
        }
        return path
    }

    private func rebuildSegmentIndex() {
        var index: [NodeID: Int] = [:]
        var smaller: [NodeID: Int] = [:]
        index.reserveCapacity(layout.segments.count)
        for (i, s) in layout.segments.enumerated() {
            if let node = s.node { index[node] = i } else { smaller[s.parent] = i }
        }
        segmentIndex = index
        smallerIndex = smaller
    }

    /// The node at `path` unless it is missing or hidden by the overlay.
    private static func visibleNode(atPath path: String, in view: TreeView) -> NodeID? {
        guard let node = view.tree.node(atPath: path), !view.isHidden(node) else { return nil }
        return node
    }

    private static func computeLayout(view: TreeView, root: NodeID) -> SunburstLayout {
        let t0 = Timings.now
        let layout = SunburstLayout(view: view, root: root)
        Timings.mark("layout", (Timings.now - t0) * 1000)
        return layout
    }

    /// Reads free space off the main actor when the scan root is a volume
    /// root (on open, and again after a delete).
    func refreshVolumeSpace() {
        let path = tree.rootPath
        Task {
            let space = await Task.detached(priority: .utility) { () -> (Int64, Int64)? in
                let url = URL(fileURLWithPath: path)
                let keys: Set<URLResourceKey> = [.isVolumeKey, .volumeAvailableCapacityKey,
                                                 .volumeAvailableCapacityForImportantUsageKey]
                guard let v = try? url.resourceValues(forKeys: keys), v.isVolume == true,
                      let free = v.volumeAvailableCapacity,
                      let purgeable = v.volumeAvailableCapacityForImportantUsage else { return nil }
                return (Int64(free), purgeable)
            }.value
            if let space { volumeSpace = (space.0, space.1) }
        }
    }
}
