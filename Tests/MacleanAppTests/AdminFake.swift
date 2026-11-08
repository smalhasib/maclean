import Foundation
@testable import Maclean

/// Base for `AdminRunning` fakes: answers each invocation of a batch through
/// `runOne` with exit status 0, and records the prompts it was given.
class AdminFake: AdminRunning, @unchecked Sendable {
    private let promptLock = NSLock()
    private var _prompts: [String] = []
    var prompts: [String] { promptLock.withLock { _prompts } }

    /// One invocation's standard output. Subclasses override.
    func runOne(_ arguments: [String]) async throws -> String { "" }

    final func run(_ invocations: [[String]], prompt: String) async throws -> [AdminOutput] {
        promptLock.withLock { _prompts.append(prompt) }
        var outputs: [AdminOutput] = []
        for arguments in invocations { outputs.append(AdminOutput(stdout: try await runOne(arguments), status: 0)) }
        return outputs
    }
}
