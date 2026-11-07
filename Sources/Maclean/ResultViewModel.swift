import Foundation
import MacleanCore
import MacleanKit
import Observation

/// State of one result window: where it is in the tree (history of paths),
/// the chart layout for that folder, and hover/selection.
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
    /// Recomputed on navigation only.
    private(set) var layout: SunburstLayout
    /// Bumped whenever `layout` is replaced (drives the chart's transition).
    private(set) var layoutGeneration = 0

    var hovered: NodeID?
    private(set) var hoverSource: HoverSource = .chart
    var selected: NodeID?
    /// The list target whose "smaller objects" row was clicked open.
    var expandedTarget: NodeID?
    /// The toolbar control holding the keyboard focus (Tab cycle: toolbar →
    /// list → chart); nil when the list or chart has it.
    var toolbarFocus: ToolbarItem?

    enum ToolbarItem: Hashable { case back, forward, disks, crumb(String) }

    var expandSmallerObjects: Bool {
        didSet { defaults.set(expandSmallerObjects, forKey: Self.alwaysExpandKey) }
    }

    /// An inline message ("… no longer exists"); `id` restarts its dismiss timer.
    struct Notice: Equatable {
        let id = UUID()
        let text: String
    }
    private(set) var notice: Notice?

    /// Volume roots only: (free, free including purgeable) bytes.
    private(set) var volumeSpace: (free: Int64, freePurgeable: Int64)?

    /// What the side list shows: the chart-hovered item, else the current folder.
    var listTarget: NodeID {
        if hoverSource == .chart, let hovered { return hovered }
        return currentNode
    }

    /// What keyboard actions apply to: under the pointer first, else the selection.
    var actionTarget: NodeID? { hovered ?? selected }

    @ObservationIgnored private let defaults: UserDefaults
    /// Whether navigation is written back to `session.history` (the main
    /// window's result, so View returns to where it was). Other windows on
    /// the session keep their own history.
    @ObservationIgnored private let ownsSessionHistory: Bool
    @ObservationIgnored private var currentPath: String
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

        var history = start ?? session.history
        if let startPath { history.visit(startPath) }
        let node = Self.resolve(history.current, in: tree)
        if node == nil { history = NavigationHistory(rootPath: tree.rootPath) }
        self.history = history
        currentNode = node ?? tree.root
        currentPath = history.current
        layout = Self.computeLayout(tree: tree, root: node ?? tree.root)
        rebuildSegmentIndex()
        if let selectedPath, let node = Self.resolve(selectedPath, in: tree), node != currentNode {
            selected = node
        }
        loadVolumeSpace()
    }

    /// A model for `tree` (a rescan of `old`'s session) that keeps `old`'s
    /// current folder, back/forward history and selection by path; vanished
    /// paths fall back to their nearest surviving ancestor.
    convenience init(remapping old: ResultViewModel, to tree: FileTree, ownsSessionHistory: Bool) {
        var history = old.history
        history.remap { Self.resolve($0, in: tree) != nil }
        self.init(session: old.session, history: history, selectedPath: old.selected.map { old.tree.path(of: $0) },
                  ownsSessionHistory: ownsSessionHistory, defaults: old.defaults)
    }

    // MARK: Navigation

    /// Drills into a folder (or a package, for Show Package Contents).
    func open(_ node: NodeID) {
        guard tree.flags(of: node).contains(.directory), node != currentNode else { return }
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
        let kids = tree.children(of: currentNode).count
        let visible = visibleChildCount(of: currentNode)
        guard isExpanded(currentNode) else { return visible }
        return min(kids, visible + Self.expandedRowLimit)
    }

    /// The selection's row in the current folder's list, if it is one.
    var selectedRow: Int? {
        guard let selected, tree.parent(of: selected) == currentNode else { return nil }
        guard let i = tree.children(of: currentNode).firstIndex(of: selected), i < listRowCount else { return nil }
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
        selected = tree.children(of: currentNode)[min(max(target, 0), count - 1)]
    }

    /// Arrow keys in the chart: ←/→ between siblings, ↑ out, ↓ in.
    func traverse(_ step: Traversal) {
        guard let selected, selected != currentNode, isInside(selected) else {
            let kids = tree.children(of: currentNode)
            if visibleChildCount(of: currentNode) > 0 { self.selected = kids[0] }
            return
        }
        switch step {
        case .previous, .next:
            guard let parent = tree.parent(of: selected) else { return }
            let kids = tree.children(of: parent)
            guard let i = kids.firstIndex(of: selected) else { return }
            let count = max(visibleChildCount(of: parent), i + 1)
            let j = min(max(i + (step == .next ? 1 : -1), 0), count - 1)
            self.selected = kids[j]
        case .out:
            if let parent = tree.parent(of: selected), parent != currentNode { self.selected = parent }
        case .into:
            if tree.flags(of: selected).contains(.directory), visibleChildCount(of: selected) > 0 {
                self.selected = tree.children(of: selected)[0]
            }
        }
    }

    /// A selection for the chart's keyboard focus after a navigation: kept if
    /// it is inside the current folder; after going up, the folder the user
    /// came from (its ancestor among the current children); else the first child.
    func selectForKeyboardFocus() {
        if let selected, selected != currentNode, isInside(selected) { return }
        if var node = previousFolder, node != currentNode, isInside(node) {
            while let parent = tree.parent(of: node), parent != currentNode { node = parent }
            selected = node
        } else if visibleChildCount(of: currentNode) > 0 {
            selected = tree.children(of: currentNode)[0]
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
    var toolbarItems: [ToolbarItem] { [.back, .forward, .disks] + crumbs.map { .crumb($0.path) } }

    func isEnabled(_ item: ToolbarItem) -> Bool {
        switch item {
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
        visibleChildCount(of: listTarget) < tree.children(of: listTarget).count
    }

    // MARK: Notices

    func reportMissing(_ node: NodeID) {
        notice = Notice(text: "“\(name(of: node))” no longer exists")
    }

    func dismissNotice(_ id: UUID? = nil) {
        if id == nil || notice?.id == id { notice = nil }
    }

    // MARK: Hover

    func hover(_ node: NodeID?, from source: HoverSource) {
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
        let flags = tree.flags(of: node)
        guard flags.contains(.directory) else { return .file }
        if flags.contains(.package) { return .package }
        if flags.contains(.restricted) { return .restricted }
        if flags.contains(.mountPoint) { return .mountPoint }
        return .folder
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
        "\(name(of: node)), \(Self.kindWord(kind(of: node))), \(SizeText.spoken(tree.size(of: node)))"
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
        let kids = tree.children(of: node)
        let total = tree.size(of: node)
        guard total > 0 else { return 0 }
        let cutoff = Double(total) * Self.smallShare
        var lo = 0, hi = kids.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let size = tree.size(of: kids[mid])
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
        let path = history.current
        guard path != currentPath else { return }
        let node = pendingNode ?? Self.resolve(path, in: tree)
        pendingNode = nil
        guard let node else {
            // Shouldn't happen (history is remapped on rescan); stay at the root.
            history = NavigationHistory(rootPath: tree.rootPath)
            return
        }
        currentPath = path
        previousFolder = currentNode
        currentNode = node
        hovered = nil
        hoverSource = .chart
        selected = nil
        expandedTarget = nil
        layout = Self.computeLayout(tree: tree, root: node)
        layoutGeneration += 1
        rebuildSegmentIndex()
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

    private static func computeLayout(tree: FileTree, root: NodeID) -> SunburstLayout {
        let t0 = Timings.now
        let layout = SunburstLayout(tree: tree, root: root)
        Timings.mark("layout", (Timings.now - t0) * 1000)
        return layout
    }

    /// The node at `path`, walking down from the root by name.
    static func resolve(_ path: String, in tree: FileTree) -> NodeID? {
        let root = tree.rootPath
        if path == root { return tree.root }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        var node = tree.root
        for component in path.dropFirst(prefix.count).split(separator: "/") {
            guard let next = tree.children(of: node).first(where: { tree.name(of: $0) == component }) else {
                return nil
            }
            node = next
        }
        return node
    }

    /// Reads free space off the main actor when the scan root is a volume root.
    private func loadVolumeSpace() {
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
