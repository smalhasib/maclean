import Foundation
import Testing
@testable import Maclean

/// Records each batch and answers it from a script (status per invocation).
private final class Runner: AdminRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(invocations: [[String]], prompt: String)] = []
    private let answer: @Sendable ([[String]]) throws -> [AdminOutput]

    init(_ answer: @escaping @Sendable ([[String]]) throws -> [AdminOutput]) { self.answer = answer }

    var calls: [(invocations: [[String]], prompt: String)] { lock.withLock { _calls } }

    func run(_ invocations: [[String]], prompt: String) async throws -> [AdminOutput] {
        lock.withLock { _calls.append((invocations, prompt)) }
        return try answer(invocations)
    }
}

@MainActor private func batcher(_ runner: Runner) -> AdminBatcher {
    AdminBatcher(runner: runner, coordinator: PromptCoordinator(hasAccess: { true }))
}

@Test @MainActor func batcherMergesConcurrentSubmissions() async throws {
    let runner = Runner { $0.map { AdminOutput(stdout: "out-" + $0[0], status: 0) } }
    let b = batcher(runner)
    let first = Task { try await b.submit(["a"], reason: "Reason A.") }
    let second = Task { try await b.submit(["b"], reason: "Reason B.") }
    #expect(try await first.value == "out-a")
    #expect(try await second.value == "out-b")
    #expect(runner.calls.count == 1)
    #expect(runner.calls.first?.invocations == [["a"], ["b"]])
    #expect(runner.calls.first?.prompt == "Reason A. Reason B.")
}

@Test @MainActor func batcherCancelReachesAllCallers() async {
    let runner = Runner { _ in throw AdminRunnerError.cancelled }
    let b = batcher(runner)
    let first = Task { try await b.submit(["a"], reason: "A.") }
    let second = Task { try await b.submit(["b"], reason: "B.") }
    for task in [first, second] {
        await #expect(throws: AdminRunnerError.cancelled) { try await task.value }
    }
    #expect(runner.calls.count == 1)
}

@Test @MainActor func batcherFailedInvocationFailsOnlyItsCaller() async throws {
    let runner = Runner { $0.map { AdminOutput(stdout: "out", status: $0[0] == "bad" ? 2 : 0) } }
    let b = batcher(runner)
    let good = Task { try await b.submit(["good"], reason: "A.") }
    let bad = Task { try await b.submit(["bad"], reason: "B.") }
    #expect(try await good.value == "out")
    await #expect(throws: AdminRunnerError.self) { try await bad.value }
    #expect(runner.calls.count == 1)
}

@Test @MainActor func batcherSubmissionDuringRunGetsNextDialog() async throws {
    let runner = Runner { $0.map { AdminOutput(stdout: $0[0], status: 0) } }
    let b = batcher(runner)
    #expect(try await b.submit(["a"], reason: "A.") == "a")
    #expect(try await b.submit(["b"], reason: "B.") == "b")
    #expect(runner.calls.map(\.prompt) == ["A.", "B."])
}
