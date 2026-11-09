import Foundation
import MacleanCore
import MacleanKit
import Observation

protocol DeleterProtocol: Sendable {
    func delete(_ r: DeleteRequest, force: Bool) async -> DeleteOutcome
}

extension Deleter: DeleterProtocol {}

extension Notification.Name {
    /// Posted (object: the `ScanSession`) after a delete run that removed anything.
    static let macleanDidDelete = Notification.Name("MacleanDidDelete")
}

/// Deletes a session's collected items: a confirmation, a 5 s countdown (cancellable), then
/// one item at a time off the main actor (Stop takes effect between items),
/// then one administrator batch for the items that need it, then a summary.
///
/// Deleted and already-gone items leave the collector when the run ends;
/// every other item stays collected. The session is marked `isDeleting` from
/// the countdown until the summary appears (and again during Delete Anyway),
/// so Rescan works while the summary is up.
@MainActor @Observable final class DeleteController {
    enum Phase: Equatable {
        case idle
        /// Asked "Delete N items?"; nothing is snapshotted for deleting yet.
        case confirming
        case countdown(remaining: Int)
        case running(done: Int, total: Int)
        case summary(DeleteReport)
    }

    /// UserDefaults key of Settings' "Move to Trash instead of deleting permanently".
    static let trashKey = "MoveToTrashInsteadOfDeleting"
    static let countdownSeconds = 5
    static let trashNeedsAdmin = DeleteBatch.trashNeedsAdmin
    static let adminNotGiven = DeleteBatch.adminNotGiven
    static let stoppedBeforeAdmin = DeleteBatch.stoppedBeforeAdmin
    static let adminNoReport = DeleteBatch.adminNoReport

    private(set) var phase: Phase = .idle
    /// The mode of the current (or last) run, read from Settings at `start()`.
    private(set) var mode: DeleteMode = .permanent
    /// The items and total size the countdown announces.
    private(set) var pendingCount = 0
    private(set) var pendingSize: Int64 = 0
    /// The item's name when exactly one is pending (the confirmation names it).
    private(set) var pendingName: String?
    /// True while the administrator prompt (and the helper) runs; Stop is
    /// unavailable then.
    var awaitingAdmin: Bool { batch?.awaitingAdmin ?? false }
    /// The running run's engine.
    private var batch: DeleteBatch?

    @ObservationIgnored private weak var session: ScanSession?
    @ObservationIgnored private let makeDeleter: (DeleteMode) -> any DeleterProtocol
    @ObservationIgnored private let admin: any AdminRunning
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var report = DeleteReport()
    /// Set by `requestDelete(item:)`: the run deletes only these, not the whole collector.
    @ObservationIgnored private var subset: Set<NodeID>?
    /// Items `requestDelete(item:)` had to collect itself; they go back if the delete is cancelled.
    @ObservationIgnored private var autoCollected: [NodeID] = []
    /// The snapshot taken at `start()`, by path (for Delete Anyway).
    @ObservationIgnored private var entries: [String: Entry] = [:]
    /// The tree the snapshot's node ids belong to.
    @ObservationIgnored private var tree: FileTree?

    private struct Entry {
        let request: DeleteRequest
        let node: NodeID
    }

    init(session: ScanSession,
         deleter: @escaping (DeleteMode) -> any DeleterProtocol = { Deleter(mode: $0, environment: .current()) },
         admin: any AdminRunning = AdminRunner(),
         clock: any Clock<Duration> = ContinuousClock(),
         defaults: UserDefaults = .standard) {
        self.session = session
        makeDeleter = deleter
        self.admin = admin
        self.clock = clock
        self.defaults = defaults
    }

    /// Deleting (or waiting for the administrator step), past the countdown.
    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// Counting down or running.
    var isActive: Bool {
        switch phase {
        case .countdown, .running: true
        case .idle, .confirming, .summary: false
        }
    }

    // MARK: Actions

    /// Every user-facing Delete goes through here: asks for confirmation first
    /// (the alert reads `pendingCount`, `pendingSize` and `mode`). A no-op
    /// unless idle with something collected.
    func requestDelete() {
        guard phase == .idle, let session, !session.isDeleting, let view = session.view,
              !view.collected.isEmpty else { return }
        mode = defaults.bool(forKey: Self.trashKey) ? .trash : .permanent
        subset = nil
        autoCollected = []
        pendingCount = view.collected.count
        pendingSize = view.collectedSize
        pendingName = view.collected.count == 1 ? view.tree.name(of: view.collected[0]) : nil
        phase = .confirming
    }

    /// Delete from one item's row (hover button, context menu): collects it if it isn't
    /// collected yet, then asks. Only that item is deleted, whatever else is in the collector.
    /// Returns why the item can't be deleted (protected locations are refused as in the
    /// collector); nil when it asks, or when there's nothing to do.
    @discardableResult
    func requestDelete(item node: NodeID) -> Refusal? {
        guard phase == .idle, let session, !session.isDeleting, let before = session.view else { return nil }
        var added = false
        if !before.collected.contains(node) {
            if let refusal = session.collect([node]).first { return refusal.1 }
            added = session.view?.collected.contains(node) == true
            guard added else { return nil }   // hidden or gone
        }
        guard let view = session.view else { return nil }
        mode = defaults.bool(forKey: Self.trashKey) ? .trash : .permanent
        subset = [node]
        autoCollected = added ? [node] : []
        pendingCount = 1
        pendingSize = view.tree.size(of: node)
        pendingName = view.tree.name(of: node)
        phase = .confirming
        return nil
    }

    /// The confirmation was accepted: starts the countdown.
    func confirmDelete() {
        guard phase == .confirming else { return }
        phase = .idle
        start()
    }

    /// The confirmation was dismissed. Only acts while still confirming: the
    /// alert also reports "dismissed" after its Delete button, by which time
    /// the countdown is running and must be left alone.
    func cancelConfirmation() {
        guard phase == .confirming else { return }
        phase = .idle
        putBackAutoCollected()
    }

    /// A row's Delete collected the item only to delete it: if that falls through, it goes back.
    private func putBackAutoCollected() {
        let items = autoCollected
        autoCollected = []
        subset = nil
        if !items.isEmpty { session?.uncollect(items) }
    }

    /// The alert's wording: what will be deleted and whether it can be undone.
    static func confirmCopy(count: Int, size: Int64, mode: DeleteMode,
                            name: String? = nil) -> (title: String, message: String) {
        let items = count == 1 ? (name.map { "“\($0)”" } ?? "1 item") : "\(count.formatted()) items"
        if mode == .trash {
            return ("Move \(items) (\(SizeText.string(size))) to the Trash?",
                    "You can restore \(count == 1 ? "it" : "them") from the Trash until it's emptied.")
        }
        return ("Delete \(items) (\(SizeText.string(size)))?",
                "\(count == 1 ? "It" : "They") will be deleted permanently. This can't be undone.")
    }

    /// Snapshots the collected items and starts the countdown. A no-op
    /// unless idle with something collected.
    func start() {
        guard phase == .idle, let session, !session.isDeleting, let view = session.view,
              !view.collected.isEmpty else { return }
        let tree = view.tree
        let nodes = subset.map { s in view.collected.filter(s.contains) } ?? view.collected
        guard !nodes.isEmpty else { return }
        subset = nil
        let snapshot = nodes.map { id in
            Entry(request: DeleteRequest(path: tree.path(of: id), inode: tree.inode(of: id), device: tree.device(of: id),
                                         size: tree.size(of: id), fileCount: tree.fileCount(of: id),
                                         isDirectory: tree.flags(of: id).contains(.directory)),
                  node: id)
        }
        self.tree = tree
        entries = Dictionary(snapshot.map { ($0.request.path, $0) }, uniquingKeysWith: { a, _ in a })
        mode = defaults.bool(forKey: Self.trashKey) ? .trash : .permanent
        pendingCount = snapshot.count
        pendingSize = nodes.reduce(0) { $0 + tree.size(of: $1) }
        report = DeleteReport()
        stopRequested = false
        session.isDeleting = true
        phase = .countdown(remaining: Self.countdownSeconds)

        let clock = clock
        task = Task {
            for remaining in stride(from: Self.countdownSeconds, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                phase = .countdown(remaining: remaining)
                do { try await clock.sleep(for: .seconds(1)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            autoCollected = []   // past the countdown: it's a delete now
            await run(snapshot, force: false)
        }
    }

    /// During the countdown: back to idle, nothing deleted. While running:
    /// stops after the current item (queued administrator items are reported
    /// as stopped). Not while the administrator prompt is up.
    func cancel() {
        switch phase {
        case .countdown:
            task?.cancel()
            task = nil
            let putBack = autoCollected
            reset()
            if !putBack.isEmpty { session?.uncollect(putBack) }
        case .running:
            if !awaitingAdmin { stopRequested = true }
        case .idle, .confirming, .summary:
            break
        }
    }

    /// The session is being forgotten. Returns whether that may go ahead:
    /// a countdown is cancelled (nothing deleted) and a summary dismissed,
    /// but a running delete refuses (it must finish where it can be seen).
    func abandonForForget() -> Bool {
        switch phase {
        case .idle: return true
        case .confirming: cancelConfirmation(); return true
        case .countdown: cancel(); return true
        case .summary: dismissSummary(); return true
        case .running: return false
        }
    }

    /// No result window shows the session any more: a countdown is cancelled
    /// (nothing deleted) and a run stops after the current item. A summary
    /// waits for the next window on the session.
    func noWindowLeft() {
        switch phase {
        case .confirming: cancelConfirmation()
        case .countdown: cancel()
        case .running: stopRequested = true
        case .idle, .summary: break
        }
    }

    /// Summary action for items under "Changed since the scan": delete them
    /// anyway (again, skipping the changed check), or keep them collected.
    func resolveChanged(_ paths: [String], deleteAnyway: Bool) {
        guard case .summary = phase else { return }
        let targets = paths.filter { report.changed[$0] != nil }
        for path in targets { report.changed[path] = nil }
        let rerun = deleteAnyway ? targets.compactMap { entries[$0] } : []
        guard !rerun.isEmpty else {
            phase = .summary(report)
            return
        }
        stopRequested = false
        session?.isDeleting = true
        phase = .running(done: 0, total: rerun.count)
        task = Task { await run(rerun, force: true) }
    }

    func dismissSummary() {
        guard case .summary = phase else { return }
        reset()
    }

    // MARK: Run

    private func run(_ items: [Entry], force: Bool) async {
        let batch = DeleteBatch(mode: mode, context: .collector, makeDeleter: { [makeDeleter] m, _ in makeDeleter(m) },
                                admin: admin)
        self.batch = batch
        phase = .running(done: 0, total: items.count)
        let result = await batch.run(items.map { DeleteBatch.Item(request: $0.request, force: force) },
                                     shouldStop: { [unowned self] in stopRequested },
                                     progress: { [unowned self] done, total in phase = .running(done: done, total: total) },
                                     beforeEach: { _ in nil })
        self.batch = nil
        merge(result)
        task = nil
        phase = .summary(report)
        // The summary is up: the session is free again (a rescan may run).
        // Delete Anyway sets it for its own run.
        session?.isDeleting = false
        if !result.deleted.isEmpty { NotificationCenter.default.post(name: .macleanDidDelete, object: session) }
    }

    /// Adds a run's `result` to the report and moves deleted and vanished
    /// items out of the collector.
    private func merge(_ result: DeleteReport) {
        report.freed += result.freed
        report.deleted += result.deleted
        report.alreadyGone += result.alreadyGone
        report.changed.merge(result.changed) { _, new in new }
        report.failed.merge(result.failed) { _, new in new }
        for path in result.deleted + result.alreadyGone { if let entry = entries[path] { markRemoved(entry) } }
    }

    private func markRemoved(_ entry: Entry) {
        // Node ids belong to the snapshot's tree: skip if a rescan replaced it.
        guard let session, let tree, session.view?.tree === tree else { return }
        session.markRemoved([entry.node])
    }

    private func reset() {
        autoCollected = []
        subset = nil
        phase = .idle
        entries = [:]
        tree = nil
        report = DeleteReport()
        session?.isDeleting = false
    }
}

extension ScanSession {
    /// The session's delete controller, created on first use.
    var deletion: DeleteController {
        if let deletionController { return deletionController }
        let controller = DeleteController(session: self)
        deletionController = controller
        return controller
    }
}
