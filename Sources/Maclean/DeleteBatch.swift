import Foundation
import MacleanCore
import Observation

/// What a delete run did, shown in the summary sheet. Paths are the
/// requests' absolute paths.
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

/// The delete engine shared by the collector and Smart Clean: one item at a
/// time off the main actor (Stop takes effect between items), then one
/// administrator batch for the items that need it, mapped into a report.
@MainActor @Observable final class DeleteBatch {
    struct Item {
        let request: DeleteRequest
        /// Skip the changed-since-scan re-walk (Delete Anyway).
        var force: Bool = false
        /// Overrides the batch's mode for this item.
        var mode: DeleteMode?
    }

    static let trashNeedsAdmin = "Needs administrator rights, so it can't be moved to the Trash. "
        + "Turn off “Move to Trash” in Settings to delete it."
    static let adminNotGiven = "Administrator password not given."
    static let stoppedBeforeAdmin = "Stopped before the administrator step."
    static let adminNoReport = "The administrator step didn't report back. It may still be running — rescan to check."

    /// True while the administrator prompt (and the helper) runs.
    private(set) var awaitingAdmin = false

    @ObservationIgnored private let mode: DeleteMode
    @ObservationIgnored private let context: ProtectionContext
    @ObservationIgnored private let makeDeleter: (DeleteMode, ProtectionContext) -> any DeleterProtocol
    @ObservationIgnored private let admin: any AdminRunning
    @ObservationIgnored private var report = DeleteReport()

    init(mode: DeleteMode, context: ProtectionContext,
         makeDeleter: @escaping (DeleteMode, ProtectionContext) -> any DeleterProtocol, admin: any AdminRunning) {
        self.mode = mode
        self.context = context
        self.makeDeleter = makeDeleter
        self.admin = admin
    }

    /// Deletes `items` in order. `beforeEach` returns a reason to skip an item
    /// (reported as failed, never deleted); `progress` gets (done, total)
    /// after each item; `shouldStop` is asked before each item and before the
    /// administrator step, which stopped items then skip.
    func run(_ items: [Item], shouldStop: () -> Bool, progress: (Int, Int) -> Void,
             beforeEach: (Item) -> String?) async -> DeleteReport {
        report = DeleteReport()
        var deleters: [DeleteMode: any DeleterProtocol] = [:]
        var queue: [Item] = []
        progress(0, items.count)
        for (i, item) in items.enumerated() {
            if shouldStop() { break }
            if let reason = beforeEach(item) {
                report.failed[item.request.path] = reason
            } else {
                let itemMode = item.mode ?? mode
                let deleter = deleters[itemMode] ?? makeDeleter(itemMode, context)
                deleters[itemMode] = deleter
                let outcome = await deleter.delete(item.request, force: item.force)
                if case .needsAdmin(let started, let verified) = outcome {
                    // Started or verified items skip root's re-walk: it would see
                    // the formerly unreadable contents and call them changed.
                    var queued = item
                    queued.force = item.force || started || verified
                    queue.append(queued)
                } else {
                    apply(outcome, to: item.request.path)
                }
            }
            progress(i + 1, items.count)
        }
        if shouldStop() {
            for item in queue { report.failed[item.request.path] = Self.stoppedBeforeAdmin }
        } else if !queue.isEmpty {
            await escalate(queue)
        }
        return report
    }

    /// Runs the queued items through the administrator helper. An item whose
    /// mode is the Trash can't use it.
    private func escalate(_ queue: [Item]) async {
        var queue = queue
        for item in queue where (item.mode ?? mode) != .permanent {
            report.failed[item.request.path] = Self.trashNeedsAdmin
        }
        queue.removeAll { ($0.mode ?? mode) != .permanent }
        guard !queue.isEmpty else { return }
        let items = queue.map { AdminDelete.Item(request: $0.request, force: $0.force) }
        let output: String
        awaitingAdmin = true
        defer { awaitingAdmin = false }
        do {
            let (file, sha256) = try AdminDelete.writeItemsFile(items)
            defer { AdminDelete.removeItemsFile(file) }
            output = try await admin.run(AdminDelete.arguments(itemsFile: file.path, sha256: sha256,
                                                               environment: .current(), context: context))
        } catch {
            // Anything but a cancelled prompt: root may have started, or may
            // still be deleting. Keep the items and say so.
            let reason = error as? AdminRunnerError == .cancelled ? Self.adminNotGiven : Self.adminNoReport
            for item in queue { report.failed[item.request.path] = reason }
            return
        }
        let outcomes = AdminDelete.decode(output)
        for item in queue {
            let path = item.request.path
            switch outcomes[path] {
            case nil: report.failed[path] = "The administrator helper gave no result."
            case .needsAdmin: report.failed[path] = "Couldn't be deleted, even with administrator rights."
            case let outcome?: apply(outcome, to: path)
            }
        }
    }

    /// Records `outcome` for the item at `path`.
    private func apply(_ outcome: DeleteOutcome, to path: String) {
        switch outcome {
        case .deleted(let freed):
            report.freed += freed
            report.deleted.append(path)
        case .missing:
            report.alreadyGone.append(path)
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
    }
}
