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

/// What a delete run did, shown in the summary sheet. Paths are the
/// collected items' absolute paths.
struct DeleteReport: Equatable {
    struct Changed: Equatable {
        var size: Int64
        var files: Int64
    }

    var freed: Int64 = 0
    var deleted: [String] = []
    var alreadyGone: [String] = []
    var changed: [String: Changed] = [:]
    var failed: [String: String] = [:]
}

/// Deletes a session's collected items: a 5 s countdown (cancellable), then
/// one item at a time off the main actor (Stop takes effect between items),
/// then one administrator batch for the items that need it, then a summary.
///
/// Deleted and already-gone items leave the collector as they finish; every
/// other item stays collected. The session is marked `isDeleting` from the
/// countdown until the summary is dismissed.
@MainActor @Observable final class DeleteController {
    enum Phase: Equatable {
        case idle
        case countdown(remaining: Int)
        case running(done: Int, total: Int)
        case summary(DeleteReport)
    }

    /// UserDefaults key of Settings' "Move to Trash instead of deleting permanently".
    static let trashKey = "MoveToTrashInsteadOfDeleting"
    static let countdownSeconds = 5
    static let trashNeedsAdmin = "Needs administrator rights, so it can't be moved to the Trash. "
        + "Turn off “Move to Trash” in Settings to delete it."
    static let adminNotGiven = "Administrator password not given."
    static let stoppedBeforeAdmin = "Stopped before the administrator step."

    private(set) var phase: Phase = .idle
    /// The mode of the current (or last) run, read from Settings at `start()`.
    private(set) var mode: DeleteMode = .permanent
    /// The items and total size the countdown announces.
    private(set) var pendingCount = 0
    private(set) var pendingSize: Int64 = 0
    /// True while the administrator prompt (and the helper) runs; Stop is
    /// unavailable then.
    private(set) var awaitingAdmin = false

    @ObservationIgnored private weak var session: ScanSession?
    @ObservationIgnored private let makeDeleter: (DeleteMode) -> any DeleterProtocol
    @ObservationIgnored private let admin: any AdminRunning
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var report = DeleteReport()
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
        case .idle, .summary: false
        }
    }

    // MARK: Actions

    /// Snapshots the collected items and starts the countdown. A no-op
    /// unless idle with something collected.
    func start() {
        guard phase == .idle, let session, !session.isDeleting, let view = session.view,
              !view.collected.isEmpty else { return }
        let tree = view.tree
        let snapshot = view.collected.map { id in
            Entry(request: DeleteRequest(path: tree.path(of: id), inode: tree.inode(of: id), device: tree.device(of: id),
                                         size: tree.size(of: id), fileCount: tree.fileCount(of: id),
                                         isDirectory: tree.flags(of: id).contains(.directory)),
                  node: id)
        }
        self.tree = tree
        entries = Dictionary(snapshot.map { ($0.request.path, $0) }, uniquingKeysWith: { a, _ in a })
        mode = defaults.bool(forKey: Self.trashKey) ? .trash : .permanent
        pendingCount = snapshot.count
        pendingSize = view.collectedSize
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
            reset()
        case .running:
            if !awaitingAdmin { stopRequested = true }
        case .idle, .summary:
            break
        }
    }

    /// The session is being forgotten. Returns whether that may go ahead:
    /// a countdown is cancelled (nothing deleted) and a summary dismissed,
    /// but a running delete refuses (it must finish where it can be seen).
    func abandonForForget() -> Bool {
        switch phase {
        case .idle: return true
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
        phase = .running(done: 0, total: rerun.count)
        task = Task { await run(rerun, force: true) }
    }

    func dismissSummary() {
        guard case .summary = phase else { return }
        reset()
    }

    // MARK: Run

    private func run(_ items: [Entry], force: Bool) async {
        let deleter = makeDeleter(mode)
        var removedAny = false
        var queue: [(entry: Entry, force: Bool)] = []
        phase = .running(done: 0, total: items.count)
        for (i, entry) in items.enumerated() {
            if stopRequested { break }
            let outcome = await deleter.delete(entry.request, force: force)
            if case .needsAdmin(let started) = outcome {
                queue.append((entry, force || started))
            } else {
                removedAny = apply(outcome, to: entry) || removedAny
            }
            phase = .running(done: i + 1, total: items.count)
        }
        if stopRequested {
            for (entry, _) in queue { report.failed[entry.request.path] = Self.stoppedBeforeAdmin }
        } else if !queue.isEmpty {
            removedAny = await escalate(queue) || removedAny
        }
        task = nil
        phase = .summary(report)
        if removedAny { NotificationCenter.default.post(name: .macleanDidDelete, object: session) }
    }

    /// Runs the queued items through the administrator helper (permanent
    /// mode only). Returns whether anything was deleted.
    private func escalate(_ queue: [(entry: Entry, force: Bool)]) async -> Bool {
        guard mode == .permanent else {
            for (entry, _) in queue { report.failed[entry.request.path] = Self.trashNeedsAdmin }
            return false
        }
        let items = queue.map { AdminDelete.Item(request: $0.entry.request, force: $0.force) }
        let output: String
        awaitingAdmin = true
        defer { awaitingAdmin = false }
        do {
            output = try await admin.run(AdminDelete.arguments(items: items, environment: .current()))
        } catch {
            let reason = switch error as? AdminRunnerError {
            case .cancelled: Self.adminNotGiven
            case .timedOut: "The administrator helper took too long."
            case .failed(let message): message
            case nil: error.localizedDescription
            }
            for (entry, _) in queue { report.failed[entry.request.path] = reason }
            return false
        }
        let outcomes = AdminDelete.decode(output)
        var removedAny = false
        for (entry, _) in queue {
            switch outcomes[entry.request.path] {
            case nil:
                report.failed[entry.request.path] = "The administrator helper gave no result."
            case .needsAdmin:
                report.failed[entry.request.path] = "Couldn't be deleted, even with administrator rights."
            case let outcome?:
                removedAny = apply(outcome, to: entry) || removedAny
            }
        }
        return removedAny
    }

    /// Records `outcome` and moves a deleted or vanished item out of the
    /// collector. Returns whether the item was deleted.
    @discardableResult
    private func apply(_ outcome: DeleteOutcome, to entry: Entry) -> Bool {
        let path = entry.request.path
        switch outcome {
        case .deleted(let freed):
            report.freed += freed
            report.deleted.append(path)
            markRemoved(entry)
            return true
        case .missing:
            report.alreadyGone.append(path)
            markRemoved(entry)
        case .changedSinceScan(let size, let files):
            report.changed[path] = DeleteReport.Changed(size: size, files: files)
        case .replaced:
            report.failed[path] = "Something else is at this location now."
        case .refused(let refusal):
            report.failed[path] = refusal.message(name: (path as NSString).lastPathComponent)
        case .failed(let message):
            report.failed[path] = message
        case .needsAdmin:
            report.failed[path] = "Needs administrator rights."
        }
        return false
    }

    private func markRemoved(_ entry: Entry) {
        // Node ids belong to the snapshot's tree: skip if a rescan replaced it.
        guard let session, let tree, session.view?.tree === tree else { return }
        session.markRemoved([entry.node])
    }

    private func reset() {
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
