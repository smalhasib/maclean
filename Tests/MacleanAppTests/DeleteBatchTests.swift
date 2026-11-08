import Foundation
import Testing
import MacleanCore
@testable import Maclean

// Fakes only: nothing on disk is touched, the paths are never opened.

private final class FakeDeleter: DeleterProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _paths: [String] = []
    private let answer: @Sendable (DeleteRequest) -> DeleteOutcome

    init(_ answer: @escaping @Sendable (DeleteRequest) -> DeleteOutcome = { .deleted(freed: $0.size) }) {
        self.answer = answer
    }

    var paths: [String] { lock.withLock { _paths } }

    func delete(_ r: DeleteRequest, force: Bool) async -> DeleteOutcome {
        lock.withLock { _paths.append(r.path) }
        return answer(r)
    }
}

private final class FakeAdmin: AdminRunning, @unchecked Sendable {
    private let answer: @Sendable () throws -> String
    init(_ answer: @escaping @Sendable () throws -> String) { self.answer = answer }
    func run(_ arguments: [String]) async throws -> String { try answer() }
}

/// Records the (mode, context) pairs the batch asked deleters for.
private final class Made: @unchecked Sendable {
    private let lock = NSLock()
    private var _pairs: [(DeleteMode, ProtectionContext)] = []
    var pairs: [(DeleteMode, ProtectionContext)] { lock.withLock { _pairs } }
    func add(_ m: DeleteMode, _ c: ProtectionContext) { lock.withLock { _pairs.append((m, c)) } }
}

private func item(_ path: String, mode: DeleteMode? = nil) -> DeleteBatch.Item {
    DeleteBatch.Item(request: DeleteRequest(path: path, inode: 1, device: 1, size: 100, fileCount: 1, isDirectory: false),
                     force: false, mode: mode)
}

@MainActor private func batch(_ mode: DeleteMode = .permanent, deleter: FakeDeleter, made: Made = Made(),
                              admin: FakeAdmin = FakeAdmin { "" }) -> DeleteBatch {
    DeleteBatch(mode: mode, context: .smartClean, makeDeleter: { m, c in made.add(m, c); return deleter }, admin: admin)
}

@Test @MainActor func beforeEachSkipsItemWithReason() async {
    let deleter = FakeDeleter()
    let b = batch(deleter: deleter)
    let report = await b.run([item("/x/a"), item("/x/b")], shouldStop: { false }, progress: { _, _ in },
                             beforeEach: { $0.request.path == "/x/a" ? "Owner changed." : nil })
    #expect(report.failed["/x/a"] == "Owner changed.")
    #expect(deleter.paths == ["/x/b"])
    #expect(report.deleted == ["/x/b"])
    #expect(report.freed == 100)
}

@Test @MainActor func perItemModeOverridesBatchMode() async {
    let deleter = FakeDeleter(), made = Made()
    let b = batch(.trash, deleter: deleter, made: made)
    _ = await b.run([item("/x/a"), item("/x/b", mode: .permanent)], shouldStop: { false }, progress: { _, _ in },
                    beforeEach: { _ in nil })
    #expect(made.pairs.map(\.0).sorted { $0.rawValue < $1.rawValue } == [.permanent, .trash])
    #expect(made.pairs.allSatisfy { $0.1 == .smartClean })
}

@Test @MainActor func cancelledAdminKeepsUserItems() async {
    let deleter = FakeDeleter { $0.path == "/x/root" ? .needsAdmin(started: false) : .deleted(freed: $0.size) }
    let b = batch(deleter: deleter, admin: FakeAdmin { throw AdminRunnerError.cancelled })
    var steps: [Int] = []
    let report = await b.run([item("/x/user"), item("/x/root")], shouldStop: { false },
                             progress: { done, total in steps.append(done * 10 + total) }, beforeEach: { _ in nil })
    #expect(report.deleted == ["/x/user"])
    #expect(report.failed["/x/root"] == DeleteController.adminNotGiven)
    #expect(steps == [2, 12, 22])
    #expect(!b.awaitingAdmin)
}

/// Records the admin argv and answers "deleted" for every path the batch sends.
private final class RecordingAdmin: AdminRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _arguments: [[String]] = []
    private var _items: [AdminDelete.Item] = []
    let paths: [String]
    init(paths: [String]) { self.paths = paths }
    var arguments: [[String]] { lock.withLock { _arguments } }
    /// The items file's contents, read while it still exists.
    var items: [AdminDelete.Item] { lock.withLock { _items } }
    func run(_ arguments: [String]) async throws -> String {
        let read = arguments.firstIndex(of: "--items-file")
            .flatMap { FileManager.default.contents(atPath: arguments[$0 + 1]) }
            .flatMap { try? JSONDecoder().decode([AdminDelete.Item].self, from: $0) } ?? []
        lock.withLock { _arguments.append(arguments); _items += read }
        return paths.map { AdminDelete.encode(path: $0, outcome: .deleted(freed: 100)) }.joined(separator: "\n")
    }
}

@Test @MainActor func adminOnlyItemSkipsUserDeleter() async {
    // A user-level attempt would partly delete it (started) and break root's age check (R27).
    let deleter = FakeDeleter { $0.path == "/Library/Logs/x" ? .needsAdmin(started: true) : .deleted(freed: $0.size) }
    let admin = RecordingAdmin(paths: ["/Library/Logs/x"])
    let b = DeleteBatch(mode: .permanent, context: .smartClean, makeDeleter: { _, _ in deleter }, admin: admin)
    var sys = item("/Library/Logs/x")
    sys.adminOnly = true
    sys.force = true
    let report = await b.run([sys, item("/x/user")], shouldStop: { false }, progress: { _, _ in },
                             beforeEach: { _ in nil })
    #expect(deleter.paths == ["/x/user"])
    #expect(admin.arguments.count == 1)
    #expect(report.deleted.sorted() == ["/Library/Logs/x", "/x/user"])
    // Root re-checks everything itself: sent without force.
    #expect(admin.items.map(\.request.path) == ["/Library/Logs/x"])
    #expect(admin.items.map(\.force) == [false])
}

@Test @MainActor func adminOnlyItemInTrashModeIsSkipped() async {
    let deleter = FakeDeleter()
    let admin = RecordingAdmin(paths: [])
    let b = DeleteBatch(mode: .trash, context: .smartClean, makeDeleter: { _, _ in deleter }, admin: admin)
    var sys = item("/Library/Logs/x")
    sys.adminOnly = true
    let report = await b.run([sys], shouldStop: { false }, progress: { _, _ in }, beforeEach: { _ in nil })
    #expect(deleter.paths.isEmpty)
    #expect(admin.arguments.isEmpty)
    #expect(report.failed["/Library/Logs/x"] == DeleteBatch.trashNeedsAdmin)
}

@Test @MainActor func smartCleanAdminStepCarriesNeverClean() async throws {
    let deleter = FakeDeleter { _ in .needsAdmin(started: false) }
    let admin = RecordingAdmin(paths: ["/x/root"])
    let b = DeleteBatch(mode: .permanent, context: .smartClean, makeDeleter: { _, _ in deleter }, admin: admin,
                        neverClean: ["/Library/Caches/keep"])
    _ = await b.run([item("/x/root")], shouldStop: { false }, progress: { _, _ in }, beforeEach: { _ in nil })
    let args = try #require(admin.arguments.first)
    let json = try #require(args.firstIndex(of: "--env").map { args[$0 + 1] })
    let env = try JSONDecoder().decode(ProtectionEnvironment.self, from: Data(json.utf8))
    #expect(env.neverClean == ["/Library/Caches/keep"])
    // The collector ignores the list.
    #expect(DeleteBatch.environment(for: .collector, neverClean: ["/a"]).neverClean.isEmpty)
    #expect(DeleteBatch.environment(for: .smartClean, neverClean: ["/a"]).neverClean == ["/a"])
}
