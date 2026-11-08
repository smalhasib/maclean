import Foundation

/// Merges administrator helper runs into as few dialogs as possible (spec
/// §6a.3): every submission that arrives before the batcher's turn with the
/// `PromptCoordinator` goes out in **one** `run`, behind one dialog whose
/// reason is all the submissions' reasons joined, and each caller gets its own
/// invocation's output.
@MainActor final class AdminBatcher {
    /// Settings › General: "Ask for the administrator password to read
    /// restricted folders" (default on). Also governs Smart Clean's automatic measure.
    nonisolated static let askKey = "access.askForAdminReads"

    nonisolated static func asksAutomatically(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: askKey) as? Bool ?? true
    }

    private struct Submission {
        let arguments: [String]
        let reason: String
        let isWanted: @MainActor () -> Bool
        let continuation: CheckedContinuation<String, any Error>
    }

    let coordinator: PromptCoordinator
    private let runner: any AdminRunning
    private var pending: [Submission] = []
    private var flushScheduled = false

    /// Submissions waiting for the next dialog (for tests).
    var pendingCount: Int { pending.count }

    init(runner: any AdminRunning, coordinator: PromptCoordinator) {
        self.runner = runner
        self.coordinator = coordinator
    }

    /// Runs `arguments` as root behind the next administrator dialog and
    /// returns its standard output. Throws `AdminRunnerError.cancelled` when the
    /// dialog is cancelled (to every caller in the batch), and
    /// `AdminRunnerError.failed` when this invocation exits non-zero (only this
    /// caller) or the whole run fails. `isWanted` is asked again when the
    /// dialog's turn comes: a submission no longer wanted (its tree was
    /// replaced, its session forgotten) is dropped with `CancellationError`
    /// and never shows in the dialog.
    func submit(_ arguments: [String], reason: String,
                isWanted: @escaping @MainActor () -> Bool = { true }) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            pending.append(Submission(arguments: arguments, reason: reason, isWanted: isWanted,
                                      continuation: continuation))
            guard !flushScheduled else { return }
            flushScheduled = true
            Task { @MainActor in await self.flush() }
        }
    }

    /// Waits for the coordinator's slot, then takes everything pending as one batch.
    private func flush() async {
        var batch: [Submission] = []
        let result: Result<[AdminOutput], any Error>
        do {
            result = try await coordinator.admin(pending.first?.reason ?? "") { [self] in
                batch = takePending().filter { submission in
                    if submission.isWanted() { return true }
                    submission.continuation.resume(throwing: CancellationError())
                    return false
                }
                guard !batch.isEmpty else { return .success([]) }
                let runner = runner
                let invocations = batch.map(\.arguments)
                let prompt = batch.map(\.reason).joined(separator: " ")
                do {
                    return .success(try await runner.run(invocations, prompt: prompt))
                } catch {
                    return .failure(error)
                }
            }
        } catch {
            // The slot was never granted: nothing ran.
            batch = takePending()
            result = .failure(error)
        }
        switch result {
        case .success(let outputs) where outputs.count == batch.count:
            for (submission, output) in zip(batch, outputs) {
                if output.status == 0 {
                    submission.continuation.resume(returning: output.stdout)
                } else {
                    submission.continuation.resume(throwing: AdminRunnerError.failed("helper exited \(output.status)"))
                }
            }
        case .success:
            for submission in batch { submission.continuation.resume(throwing: AdminRunnerError.failed(AdminRunner.malformed)) }
        case .failure(let error):
            for submission in batch { submission.continuation.resume(throwing: error) }
        }
    }

    /// Empties the queue; a later submission schedules the next flush.
    private func takePending() -> [Submission] {
        let batch = pending
        pending = []
        flushScheduled = false
        return batch
    }
}
