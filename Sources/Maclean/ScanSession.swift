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
        // Strong captures: the session lives at least until its scan ends.
        task = Task {
            let result: Result<FileTree, any Error>
            do {
                let tree = try await Scanner.scan(path: path) { progress in
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
