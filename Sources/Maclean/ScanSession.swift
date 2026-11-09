import Foundation
import MacleanCore
import MacleanKit
import Observation

/// One scan of one root path: owns the scan task, its progress, the result
/// tree, its collector overlay (shared by every window on the session) and
/// the navigation history (stored as paths, so it survives rescans).
@MainActor @Observable final class ScanSession: Identifiable {
    enum State {
        case scanning(bytes: Int64, expected: Int64?)
        case finished(FileTree)
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let rootPath: String
    /// Bytes the scan is measured against (a volume's used bytes); nil shows
    /// indeterminate progress.
    let expected: Int64?
    private(set) var state: State = .cancelled
    /// True between `cancel()` and the scan task actually ending.
    private(set) var isStopping = false
    /// Written back by the result window so a rescan can remap where it was.
    var history: NavigationHistory
    /// Called on the main actor each time a scan finishes successfully.
    var onFinish: ((ScanSession) -> Void)?

    /// The collector overlay on the finished tree; nil while scanning, after a
    /// failure, or before the first scan. Windows keep their last copy meanwhile.
    private(set) var view: TreeView?
    /// True while a delete counts down or runs (not while its summary is up,
    /// so Rescan works then); collect and uncollect are no-ops, as is a
    /// rescan (`markRemoved` stays allowed: the delete run calls it).
    var isDeleting = false
    /// Collected paths the last rescan couldn't find; the result window shows
    /// a note and clears it.
    private(set) var carryOverDropped: Int?
    /// `.restricted` nodes in the finished tree (folders this user couldn't open).
    private(set) var restrictedCount = 0
    /// The restricted folders a root read would ask for: restricted nodes
    /// with no restricted ancestor, never a mount point. The dialog's and the
    /// banner's count.
    private(set) var restrictedRoots: [String] = []
    /// Folders macOS privacy protection kept closed (`.privacy`): only Full
    /// Disk Access opens them, so they are never sent to root.
    private(set) var privacyCount = 0
    /// After a root read of the restricted folders: how many of them are
    /// still unreadable (root refused, so they need Full Disk Access). Nil
    /// before a read of this tree, or after a cancelled or failed one.
    private(set) var stillNeedsAccessCount: Int?
    /// Whether Full Disk Access was on when the current scan started. It decides what the
    /// "couldn't be read" banner can offer (see `RestrictedNotice`).
    private(set) var scannedWithAccess = false
    /// Answers "is Full Disk Access on?" (replaced in tests).
    @ObservationIgnored var accessProbe: () -> Bool = { FullDiskAccess.isGranted() }
    /// The tree a `readRestricted` is waiting on or reading for.
    private var readingTree: FileTree?
    /// True while a read for the current tree waits for the dialog or reads the result.
    var isReadingRestricted: Bool { readingTree != nil && readingTree === tree }
    /// Set when the registry forgets this session: it never asks for a password again.
    var isForgotten = false
    /// Protection environment for collect-time refusals. Read fresh on each
    /// use (it checks mounts), unless a test sets it.
    var protection: ProtectionEnvironment {
        get { protectionOverride ?? .current() }
        set { protectionOverride = newValue }
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    /// The last finished tree, restored if a rescan is cancelled.
    @ObservationIgnored private var previousTree: FileTree?
    /// The overlay of `previousTree`, restored with it.
    @ObservationIgnored private var previousView: TreeView?
    /// Collected paths to carry over into the next successful scan (kept
    /// across a failed rescan).
    @ObservationIgnored private var carryOver: [String]?
    @ObservationIgnored private var protectionOverride: ProtectionEnvironment?
    /// Storage for `deletion` (DeleteController.swift), created on first use.
    @ObservationIgnored var deletionController: DeleteController?

    init(rootPath: String, expected: Int64? = nil) {
        self.rootPath = rootPath
        self.expected = expected
        history = NavigationHistory(rootPath: rootPath)
    }

    var tree: FileTree? {
        if case .finished(let tree) = state { return tree }
        return nil
    }

    var isScanning: Bool {
        if case .scanning = state { return true }
        return false
    }

    func start() {
        guard task == nil else { return }
        if case .finished(let tree) = state {
            previousTree = tree
            previousView = view
            carryOver = view.map { v in v.collected.map { tree.path(of: $0) } }
        }
        view = nil
        isStopping = false
        state = .scanning(bytes: 0, expected: expected)
        let path = rootPath
        // Without Full Disk Access, opening the Photos library raises a consent dialog.
        let hasAccess = accessProbe()
        scannedWithAccess = hasAccess
        // Strong captures: the session lives at least until its scan ends.
        task = Task {
            let result: Result<FileTree, any Error>
            do {
                let tree = try await Scanner.scan(path: path, skipsPhotosLibraries: !hasAccess) { progress in
                    Task { @MainActor in self.report(bytes: progress.bytes) }
                }
                result = .success(tree)
            } catch {
                result = .failure(error)
            }
            self.finish(result)
        }
    }

    /// Requests cancellation; the state stays `.scanning` (shown as
    /// "Stopping…") until the scan task ends.
    func cancel() {
        guard let task, !isStopping else { return }
        isStopping = true
        task.cancel()
    }

    /// Rescans the root in full; the new tree replaces the old one and the
    /// history is remapped by path. A no-op while a delete is running (its
    /// node ids belong to the current tree).
    func rescan() {
        guard task == nil, !isDeleting else { return }
        start()
    }

    private func report(bytes: Int64) {
        guard task != nil, case .scanning = state else { return }
        state = .scanning(bytes: bytes, expected: expected)
    }

    private func finish(_ result: Result<FileTree, any Error>) {
        task = nil
        let wasStopping = isStopping
        isStopping = false
        switch result {
        case .success(let tree):
            previousTree = nil
            previousView = nil
            history.remap { tree.node(atPath: $0) != nil }
            view = carriedOver(to: tree)
            restrictedCount = Self.restrictedCount(in: tree)
            restrictedRoots = Self.restrictedRoots(in: tree)
            privacyCount = Self.privacyCount(in: tree)
            stillNeedsAccessCount = nil
            state = .finished(tree)
            onFinish?(self)
        case .failure(let error):
            if error is CancellationError || wasStopping {
                if let previousTree {
                    view = previousView ?? TreeView(tree: previousTree)
                    carryOver = nil
                    state = .finished(previousTree)
                } else {
                    state = .cancelled
                }
            } else {
                state = .failed(Self.message(for: error))
            }
            previousTree = nil
            previousView = nil
        }
    }

    /// A fresh overlay on `tree` with the previously collected paths that
    /// still exist (and aren't refused by `ProtectionRules`) collected again,
    /// re-keyed to the new nodes; removed marks are dropped, since the new
    /// tree reflects the disk.
    private func carriedOver(to tree: FileTree) -> TreeView {
        var view = TreeView(tree: tree)
        defer { carryOver = nil }
        carryOverDropped = nil
        guard let paths = carryOver, !paths.isEmpty else { return view }
        let env = protection
        let ids = paths.compactMap { path in
            ProtectionRules.refusal(for: path, in: env) == nil ? tree.node(atPath: path) : nil
        }
        let dropped = paths.count - view.collect(ids).count
        carryOverDropped = dropped > 0 ? dropped : nil
        return view
    }

    // MARK: Restricted folders

    /// The administrator dialog's reason for reading `count` restricted folders.
    static func readPrompt(count: Int) -> String {
        "Maclean needs to read \(count) folders that only an administrator can open."
    }

    /// Reads the tree's restricted folders as root (one administrator dialog,
    /// shared through `batcher`) and grafts what root could read into a new
    /// tree; the collector carries over by path. A cancel or failure leaves
    /// the tree as it is. Results are dropped if the tree was replaced or a
    /// delete started meanwhile (its node ids belong to the current tree).
    /// A read still queued for the dialog when its tree is replaced (rescan)
    /// or its session forgotten gives way and never prompts; a forgotten
    /// session never submits.
    func readRestricted(using batcher: AdminBatcher) async {
        guard !isForgotten, !isReadingRestricted, !isDeleting, let tree, !restrictedRoots.isEmpty else { return }
        let paths = restrictedRoots
        readingTree = tree
        defer { if readingTree === tree { readingTree = nil } }
        let subtrees: [String: FileTree]
        do {
            let (file, sha256) = try AdminRead.writePathsFile(paths)
            defer { AdminRead.removePathsFile(file) }
            let outDir = try AdminRead.makeOutDir()
            defer { try? FileManager.default.removeItem(at: outDir) }
            let arguments = AdminRead.arguments(root: tree.rootPath, pathsFile: file.path, sha256: sha256,
                                                outDir: outDir.path, uid: getuid())
            let output = try await batcher.submit(arguments, reason: Self.readPrompt(count: paths.count)) { [weak self] in
                guard let self else { return false }
                return !self.isForgotten && self.tree === tree && !self.isDeleting
            }
            let lines = AdminRead.decode(output)
            subtrees = await Self.readArchives(paths: paths, lines: lines, outDir: outDir.path)
        } catch {
            return
        }
        guard self.tree === tree, !isDeleting, task == nil else { return }
        let grafted = await Task.detached(priority: .userInitiated) { tree.grafting(subtrees) }.value
        guard self.tree === tree, !isDeleting, task == nil else { return }
        let remainingRoots = Self.restrictedRoots(in: grafted)
        stillNeedsAccessCount = remainingRoots.count
        guard grafted !== tree else { return }
        let removed = view.map { v in v.removed.map { tree.path(of: $0) } } ?? []
        carryOver = view.map { v in v.collected.map { tree.path(of: $0) } }
        var newView = carriedOver(to: grafted)
        newView.markDeleted(removed.compactMap { grafted.node(atPath: $0) })
        history.remap { grafted.node(atPath: $0) != nil }
        view = newView
        restrictedCount = Self.restrictedCount(in: grafted)
        restrictedRoots = remainingRoots
        privacyCount = Self.privacyCount(in: grafted)
        state = .finished(grafted)
    }

    /// Archive `outDir/<i>.mtree` for each path `i` root reported reading,
    /// read off the main actor. The archive's name is fixed here, not taken
    /// from root's output; one that is missing or unreadable is skipped.
    private nonisolated static func readArchives(paths: [String], lines: [String: AdminRead.Line],
                                                 outDir: String) async -> [String: FileTree] {
        await Task.detached(priority: .userInitiated) {
            var subtrees: [String: FileTree] = [:]
            for (index, path) in paths.enumerated() {
                guard let line = lines[path], line.error == nil, line.file != nil,
                      let subtree = try? TreeArchive.read(from: URL(fileURLWithPath: outDir + "/\(index).mtree")),
                      subtree.rootPath == path else { continue }
                subtrees[path] = subtree
            }
            return subtrees
        }.value
    }

    static func privacyCount(in tree: FileTree) -> Int {
        (0..<tree.count).reduce(0) { n, i in
            tree.flags(of: NodeID(index: Int32(i))).contains(.privacy) ? n + 1 : n
        }
    }

    static func restrictedCount(in tree: FileTree) -> Int {
        (0..<tree.count).reduce(0) { n, i in
            tree.flags(of: NodeID(index: Int32(i))).contains(.restricted) ? n + 1 : n
        }
    }

    /// Paths of the restricted nodes with no restricted ancestor, privacy
    /// folders left out (root can't open them either). Mount points are never sent (a mount the scan descended into is still
    /// searched below).
    static func restrictedRoots(in tree: FileTree) -> [String] {
        var paths: [String] = []
        var stack = [tree.root]
        while let id = stack.popLast() {
            let flags = tree.flags(of: id)
            if flags.contains(.restricted), !flags.contains(.mountPoint), id != tree.root {
                if !flags.contains(.privacy) { paths.append(tree.path(of: id)) }
                continue
            }
            stack.append(contentsOf: tree.children(of: id))
        }
        return paths
    }

    // MARK: Collector

    /// Collects `ids`, skipping each one `ProtectionRules` refuses (a refused
    /// id doesn't stop the others). Returns the refusals by node. A no-op
    /// while a delete is running or without a finished tree.
    @discardableResult
    func collect(_ ids: [NodeID]) -> [(NodeID, Refusal)] {
        guard !isDeleting, var view, !ids.isEmpty else { return [] }
        let env = protection
        var refusals: [(NodeID, Refusal)] = []
        var accepted: [NodeID] = []
        for id in ids {
            if let refusal = ProtectionRules.refusal(for: view.tree.path(of: id), in: env) {
                refusals.append((id, refusal))
            } else {
                accepted.append(id)
            }
        }
        if !view.collect(accepted).isEmpty { self.view = view }
        return refusals
    }

    /// A no-op while a delete is running.
    func uncollect(_ ids: [NodeID]) {
        guard !isDeleting else { return }
        mutateView { $0.uncollect(ids) }
    }

    /// A no-op while a delete is running.
    func uncollectAll() {
        guard !isDeleting else { return }
        mutateView { $0.uncollectAll() }
    }

    /// Size of the scanned root as it is on disk now: the scan's size less what
    /// was deleted since. Items only collected are still on disk, so they stay in.
    var sizeOnDisk: Int64? {
        guard let tree else { return nil }
        guard let view else { return tree.size(of: tree.root) }
        return view.size(of: tree.root) + view.collectedSize
    }

    /// Moves deleted items from the collector to the removed set.
    func markRemoved(_ ids: [NodeID]) { mutateView { $0.markRemoved(ids) } }

    /// Marks items deleted elsewhere (Smart Clean) removed, collected or not.
    func markDeleted(_ ids: [NodeID]) { mutateView { $0.markDeleted(ids) } }

    func clearCarryOverDropped() { carryOverDropped = nil }

    /// Applies `change` and publishes the overlay only if it changed.
    private func mutateView(_ change: (inout TreeView) -> Void) {
        guard var view else { return }
        let generation = view.generation
        change(&view)
        if view.generation != generation { self.view = view }
    }

    private static func message(for error: any Error) -> String {
        switch error as? ReadError {
        case .notFound: "This folder no longer exists"
        case .notDirectory: "This isn't a folder"
        default: "Couldn't read this folder"
        }
    }
}
