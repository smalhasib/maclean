import Foundation
import Testing
import MacleanCore
import MacleanKit
@testable import Maclean

// Every test here uses fakes: nothing on disk is deleted. The scratch folder
// only gives the session a real tree to collect from.

/// A deleter that answers from a script and records its calls.
private final class FakeDeleter: DeleterProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(path: String, force: Bool)] = []
    private let answer: @Sendable (DeleteRequest, Bool) -> DeleteOutcome
    /// Called after each delete (on the deleter's executor), e.g. to stop the run.
    var after: (@Sendable (Int) async -> Void)?

    init(_ answer: @escaping @Sendable (DeleteRequest, Bool) -> DeleteOutcome = { r, _ in .deleted(freed: r.size) }) {
        self.answer = answer
    }

    var calls: [(path: String, force: Bool)] { lock.withLock { _calls } }

    func delete(_ r: DeleteRequest, force: Bool) async -> DeleteOutcome {
        let n = lock.withLock { _calls.append((r.path, force)); return _calls.count }
        let outcome = answer(r, force)
        await after?(n)
        return outcome
    }
}

private final class FakeAdmin: AdminFake, @unchecked Sendable {
    private let lock = NSLock()
    private var _received: [[AdminDelete.Item]] = []
    private var _itemsFiles: [String] = []
    private let answer: @Sendable ([AdminDelete.Item]) throws -> String

    init(_ answer: @escaping @Sendable ([AdminDelete.Item]) throws -> String) { self.answer = answer }

    var received: [[AdminDelete.Item]] { lock.withLock { _received } }
    /// The `--items-file` paths passed (the files exist only during `run`).
    var itemsFiles: [String] { lock.withLock { _itemsFiles } }

    override func runOne(_ arguments: [String]) async throws -> String {
        // Parsed now: the controller removes the items file after the run.
        let items = (try? AdminDelete.parse(arguments).items) ?? []
        lock.withLock {
            _received.append(items)
            if let i = arguments.firstIndex(of: "--items-file"), i + 1 < arguments.count {
                _itemsFiles.append(arguments[i + 1])
            }
        }
        return try answer(items)
    }
}

/// A clock whose sleeps end only when the test advances it.
private final class TestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by d: Duration) -> Instant { Instant(offset: offset + d) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }

    private let lock = NSLock()
    private var _now = Instant(offset: .zero)
    private var sleepers: [(UUID, Instant, CheckedContinuation<Void, any Error>)] = []

    var now: Instant { lock.withLock { _now } }
    var minimumResolution: Duration { .zero }
    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if deadline <= _now || Task.isCancelled {
                    lock.unlock()
                    Task.isCancelled ? c.resume(throwing: CancellationError()) : c.resume()
                    return
                }
                sleepers.append((id, deadline, c))
                lock.unlock()
            }
        } onCancel: {
            let c = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                guard let i = sleepers.firstIndex(where: { $0.0 == id }) else { return nil }
                return sleepers.remove(at: i).2
            }
            c?.resume(throwing: CancellationError())
        }
    }

    func advance(by d: Duration) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            _now = _now.advanced(by: d)
            let due = sleepers.filter { $0.1 <= _now }
            sleepers.removeAll { $0.1 <= _now }
            return due.map(\.2)
        }
        for c in ready { c.resume() }
    }
}

@MainActor private func until(_ condition: () -> Bool) async {
    for _ in 0..<2000 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
}

/// Lets the countdown run out, then waits for the summary.
@MainActor private func runToSummary(_ c: DeleteController, _ clock: TestClock) async -> DeleteReport? {
    for _ in 0..<5 {
        await until { clock.sleeperCount > 0 }
        clock.advance(by: .seconds(1))
    }
    return await summary(c)
}

@MainActor private func summary(_ c: DeleteController) async -> DeleteReport? {
    await until { if case .summary = c.phase { true } else { false } }
    if case .summary(let r) = c.phase { return r }
    return nil
}

private struct Fixture {
    let scratch: Scratch
    let session: ScanSession
    let paths: [String]
}

/// A scanned session with `count` collected files f0…f<count-1>.
@MainActor private func fixture(_ count: Int) async throws -> Fixture {
    let s = Scratch()
    for i in 0..<count { s.file("f\(i).bin", bytes: 4096 * (i + 1)) }
    let session = await scannedSession(s)
    let tree = try #require(session.tree)
    let paths = (0..<count).map { s.path + "/f\($0).bin" }
    session.collect(paths.compactMap { tree.node(atPath: $0) })
    try #require(session.view?.collected.count == count)
    return Fixture(scratch: s, session: session, paths: paths)
}

@MainActor private func controller(_ f: Fixture, _ deleter: FakeDeleter, admin: FakeAdmin = FakeAdmin { _ in "" },
                                   clock: TestClock, trash: Bool = false) -> DeleteController {
    let defaults = UserDefaults(suiteName: "maclean-tests-\(UUID().uuidString)")!
    defaults.set(trash, forKey: DeleteController.trashKey)
    return DeleteController(session: f.session, deleter: { _ in deleter }, admin: admin, clock: clock,
                            defaults: defaults)
}

@MainActor private func collectedPaths(_ f: Fixture) -> [String] {
    let view = f.session.view!
    return view.collected.map { view.tree.path(of: $0) }.sorted()
}

@MainActor private func removedPaths(_ f: Fixture) -> [String] {
    let view = f.session.view!
    return view.removed.map { view.tree.path(of: $0) }.sorted()
}

@Test @MainActor func cancelDuringCountdownDeletesNothing() async throws {
    let f = try await fixture(3)
    let deleter = FakeDeleter(), clock = TestClock()
    let c = controller(f, deleter, clock: clock)
    c.start()
    #expect(c.phase == .countdown(remaining: 5))
    #expect(f.session.isDeleting)
    await until { clock.sleeperCount > 0 }
    clock.advance(by: .seconds(1))
    await until { c.phase == .countdown(remaining: 4) }
    c.cancel()
    #expect(c.phase == .idle)
    #expect(!f.session.isDeleting)
    clock.advance(by: .seconds(10))
    try await Task.sleep(for: .milliseconds(50))
    #expect(deleter.calls.isEmpty)
    #expect(c.phase == .idle)
    #expect(collectedPaths(f) == f.paths.sorted())
}

@Test @MainActor func stopMidRunKeepsRemainingCollected() async throws {
    let f = try await fixture(5)
    let deleter = FakeDeleter(), clock = TestClock()
    let c = controller(f, deleter, clock: clock)
    deleter.after = { n in if n == 2 { await MainActor.run { c.cancel() } } }
    c.start()
    let report = try #require(await runToSummary(c, clock))
    #expect(deleter.calls.count == 2)
    #expect(report.deleted.count == 2)
    #expect(removedPaths(f).count == 2)
    #expect(f.session.view?.collected.count == 3)
    #expect(Set(removedPaths(f)).isDisjoint(with: collectedPaths(f)))
}

@Test @MainActor func adminCancelKeepsItemsWithReason() async throws {
    let f = try await fixture(3)
    let deleter = FakeDeleter { r, _ in r.path.hasSuffix("f1.bin") ? .needsAdmin(started: false) : .deleted(freed: r.size) }
    let admin = FakeAdmin { _ in throw AdminRunnerError.cancelled }
    let clock = TestClock()
    let c = controller(f, deleter, admin: admin, clock: clock)
    c.start()
    let report = try #require(await runToSummary(c, clock))
    let f1 = f.paths[1]
    #expect(admin.received.count == 1)
    #expect(report.failed[f1] == "Administrator password not given.")
    #expect(collectedPaths(f) == [f1])
    #expect(report.deleted.sorted() == [f.paths[0], f.paths[2]])
}

@Test @MainActor func adminSendsForceForStartedItems() async throws {
    let f = try await fixture(3)
    let deleter = FakeDeleter { r, _ in
        if r.path.hasSuffix("f0.bin") { return .needsAdmin(started: true) }
        if r.path.hasSuffix("f1.bin") { return .needsAdmin(started: false) }
        return .deleted(freed: r.size)
    }
    let admin = FakeAdmin { items in
        items.map { AdminDelete.encode(path: $0.request.path, outcome: .deleted(freed: $0.request.size)) }
            .joined(separator: "\r")
    }
    let clock = TestClock()
    let c = controller(f, deleter, admin: admin, clock: clock)
    c.start()
    let report = try #require(await runToSummary(c, clock))
    let sent = try #require(admin.received.first)
    #expect(sent.map(\.request.path) == [f.paths[0], f.paths[1]])
    #expect(sent.map(\.force) == [true, false])
    #expect(report.deleted.sorted() == f.paths.sorted())
    #expect(f.session.view?.collected.isEmpty == true)
    #expect(report.freed == f.paths.indices.reduce(0) { $0 + f.session.view!.tree.size(of: f.session.view!.tree.node(atPath: f.paths[$1])!) })
}

@Test @MainActor func verifiedRestrictedItemsEscalateForced() async throws {
    let f = try await fixture(2)
    let deleter = FakeDeleter { r, _ in
        r.path.hasSuffix("f0.bin") ? .needsAdmin(started: false, verified: true) : .needsAdmin(started: false)
    }
    let admin = FakeAdmin { items in
        items.map { AdminDelete.encode(path: $0.request.path, outcome: .deleted(freed: $0.request.size)) }
            .joined(separator: "\n")
    }
    let clock = TestClock()
    let c = controller(f, deleter, admin: admin, clock: clock)
    c.start()
    let report = try #require(await runToSummary(c, clock))
    let sent = try #require(admin.received.first)
    #expect(sent.map(\.request.path) == [f.paths[0], f.paths[1]])
    #expect(sent.map(\.force) == [true, false])
    #expect(report.deleted.sorted() == f.paths.sorted())
    #expect(report.changed.isEmpty)
    // The items file is gone once the run is over.
    let file = try #require(admin.itemsFiles.first)
    #expect(!FileManager.default.fileExists(atPath: file))
    #expect(!FileManager.default.fileExists(atPath: (file as NSString).deletingLastPathComponent))
}

@Test @MainActor func realRestrictedFolderEscalatesForcedWithoutDeleting() async throws {
    let s = Scratch()
    s.file("d/a.bin", bytes: 4096)
    s.file("d/locked/secret.bin", bytes: 4096)
    let locked = s.path + "/d/locked"
    #expect(chmod(locked, 0o000) == 0)
    defer { _ = chmod(locked, 0o700) }
    let session = await scannedSession(s)
    let tree = try #require(session.tree)
    session.collect([try #require(tree.node(atPath: s.path + "/d"))])
    let admin = FakeAdmin { _ in throw AdminRunnerError.cancelled }
    let clock = TestClock()
    let env = ProtectionEnvironment(home: "/Users/maclean-test-nobody", appBundle: "/Applications/Maclean.app",
                                    mountPoints: [], timeMachineMounts: [])
    let defaults = UserDefaults(suiteName: "maclean-tests-\(UUID().uuidString)")!
    let c = DeleteController(session: session, deleter: { Deleter(mode: $0, environment: env) }, admin: admin,
                             clock: clock, defaults: defaults)
    c.start()
    let report = try #require(await runToSummary(c, clock))
    let sent = try #require(admin.received.first)
    #expect(sent.map(\.request.path) == [s.path + "/d"])
    #expect(sent.map(\.force) == [true])
    #expect(report.changed.isEmpty)
    #expect(report.failed[s.path + "/d"] == DeleteController.adminNotGiven)
    // Nothing was touched as the user: a cancelled prompt leaves the folder whole.
    #expect(FileManager.default.fileExists(atPath: s.path + "/d/a.bin"))
}

@Test @MainActor func adminFailureSaysItMayStillBeRunning() async throws {
    let f = try await fixture(2)
    let deleter = FakeDeleter { r, _ in r.path.hasSuffix("f0.bin") ? .needsAdmin(started: false) : .deleted(freed: r.size) }
    let admin = FakeAdmin { _ in throw AdminRunnerError.failed("osascript went away") }
    let clock = TestClock()
    let c = controller(f, deleter, admin: admin, clock: clock)
    c.start()
    let report = try #require(await runToSummary(c, clock))
    #expect(report.failed[f.paths[0]] == DeleteController.adminNoReport)
    #expect(collectedPaths(f) == [f.paths[0]])
}

@Test @MainActor func trashModeDoesNotEscalate() async throws {
    let f = try await fixture(2)
    let deleter = FakeDeleter { r, _ in r.path.hasSuffix("f0.bin") ? .needsAdmin(started: false) : .deleted(freed: r.size) }
    let admin = FakeAdmin { _ in "" }
    let clock = TestClock()
    let c = controller(f, deleter, admin: admin, clock: clock, trash: true)
    c.start()
    let report = try #require(await runToSummary(c, clock))
    #expect(admin.received.isEmpty)
    #expect(c.mode == .trash)
    #expect(report.failed[f.paths[0]] == DeleteController.trashNeedsAdmin)
    #expect(collectedPaths(f) == [f.paths[0]])
}

@Test @MainActor func changedThenDeleteAnywayForces() async throws {
    let f = try await fixture(2)
    let deleter = FakeDeleter { r, force in
        r.path.hasSuffix("f0.bin") && !force ? .changedSinceScan(size: 99_999, fileCount: 2) : .deleted(freed: r.size)
    }
    let clock = TestClock()
    let c = controller(f, deleter, clock: clock)
    c.start()
    let first = try #require(await runToSummary(c, clock))
    #expect(first.changed[f.paths[0]] == DeleteReport.Changed(size: 99_999, files: 2))
    #expect(collectedPaths(f) == [f.paths[0]])

    c.resolveChanged([f.paths[0]], deleteAnyway: true)
    let second = try #require(await summary(c))
    #expect(deleter.calls.last.map { $0.path == f.paths[0] && $0.force } == true)
    #expect(second.changed.isEmpty)
    #expect(second.deleted.sorted() == f.paths.sorted())
    #expect(f.session.view?.collected.isEmpty == true)
    c.dismissSummary()
    #expect(c.phase == .idle)
    #expect(!f.session.isDeleting)
}

@Test @MainActor func changedThenKeepStaysCollected() async throws {
    let f = try await fixture(1)
    let deleter = FakeDeleter { _, force in force ? .deleted(freed: 1) : .changedSinceScan(size: 1, fileCount: 1) }
    let clock = TestClock()
    let c = controller(f, deleter, clock: clock)
    c.start()
    _ = try #require(await runToSummary(c, clock))
    c.resolveChanged(f.paths, deleteAnyway: false)
    let report = try #require(await summary(c))
    #expect(report.changed.isEmpty)
    #expect(deleter.calls.count == 1)
    #expect(collectedPaths(f) == f.paths)
}

@Test @MainActor func missingCountsAsRemoved() async throws {
    let f = try await fixture(2)
    let deleter = FakeDeleter { r, _ in r.path.hasSuffix("f0.bin") ? .missing : .replaced }
    let clock = TestClock()
    let c = controller(f, deleter, clock: clock)
    c.start()
    let report = try #require(await runToSummary(c, clock))
    #expect(report.alreadyGone == [f.paths[0]])
    #expect(removedPaths(f) == [f.paths[0]])
    #expect(report.failed[f.paths[1]] != nil)
    #expect(collectedPaths(f) == [f.paths[1]])
    #expect(report.freed == 0)
}

@MainActor private func registryFixture(_ count: Int) async throws -> (SessionRegistry, Fixture) {
    let s = Scratch()
    for i in 0..<count { s.file("f\(i).bin", bytes: 4096) }
    let registry = SessionRegistry()
    let session = registry.startScan(path: s.path)
    while session.isScanning { try? await Task.sleep(for: .milliseconds(10)) }
    let tree = try #require(session.tree)
    let paths = (0..<count).map { s.path + "/f\($0).bin" }
    session.collect(paths.compactMap { tree.node(atPath: $0) })
    return (registry, Fixture(scratch: s, session: session, paths: paths))
}

@Test @MainActor func forgetDuringCountdownDeletesNothing() async throws {
    let (registry, f) = try await registryFixture(2)
    let deleter = FakeDeleter(), clock = TestClock()
    let c = controller(f, deleter, clock: clock)
    f.session.deletionController = c
    c.start()
    await until { clock.sleeperCount > 0 }
    #expect(registry.forget(path: f.session.rootPath))
    #expect(registry.session(canonical: f.session.rootPath) == nil)
    #expect(c.phase == .idle)
    for _ in 0..<6 { clock.advance(by: .seconds(1)) }
    try await Task.sleep(for: .milliseconds(50))
    #expect(deleter.calls.isEmpty)
}

@Test @MainActor func forgetIsRefusedWhileRunning() async throws {
    let (registry, f) = try await registryFixture(2)
    let deleter = FakeDeleter(), clock = TestClock()
    let c = controller(f, deleter, clock: clock)
    f.session.deletionController = c
    let root = f.session.rootPath
    let refused = Flag()
    deleter.after = { n in
        if n == 1 { await MainActor.run { refused.value = !registry.forget(path: root) } }
    }
    c.start()
    let report = try #require(await runToSummary(c, clock))
    #expect(refused.value)
    #expect(report.deleted.count == 2)
    #expect(registry.session(canonical: f.session.rootPath) === f.session)
}

@Test @MainActor func lastWindowClosingDuringCountdownDeletesNothing() async throws {
    let f = try await fixture(2)
    let deleter = FakeDeleter(), clock = TestClock()
    let c = controller(f, deleter, clock: clock)
    c.start()
    await until { clock.sleeperCount > 0 }
    c.noWindowLeft()   // what WindowRouter calls once no window shows the session
    #expect(c.phase == .idle)
    #expect(!f.session.isDeleting)
    for _ in 0..<6 { clock.advance(by: .seconds(1)) }
    try await Task.sleep(for: .milliseconds(50))
    #expect(deleter.calls.isEmpty)
    #expect(collectedPaths(f) == f.paths.sorted())
}

@Test @MainActor func lastWindowClosingWhileRunningStopsAfterCurrentItem() async throws {
    let f = try await fixture(4)
    let deleter = FakeDeleter(), clock = TestClock()
    let c = controller(f, deleter, clock: clock)
    deleter.after = { n in if n == 1 { await MainActor.run { c.noWindowLeft() } } }
    c.start()
    let report = try #require(await runToSummary(c, clock))
    #expect(deleter.calls.count == 1)
    #expect(report.deleted.count == 1)
    #expect(f.session.view?.collected.count == 3)
}

@Test @MainActor func rescanAllowedWhileSummaryShown() async throws {
    let f = try await fixture(1)
    let clock = TestClock()
    let c = controller(f, FakeDeleter(), clock: clock)
    c.start()
    #expect(f.session.isDeleting)
    _ = try #require(await runToSummary(c, clock))
    guard case .summary = c.phase else { Issue.record("expected summary"); return }
    #expect(!f.session.isDeleting)
}

@Test @MainActor func rescanIsBlockedWhileDeleting() async throws {
    let (registry, f) = try await registryFixture(1)
    let c = controller(f, FakeDeleter(), clock: TestClock())
    f.session.deletionController = c
    c.start()
    #expect(f.session.isDeleting)
    let tree = f.session.tree
    f.session.rescan()
    #expect(!f.session.isScanning)
    registry.rescan(canonical: f.session.rootPath)
    #expect(!f.session.isScanning)
    #expect(registry.startScan(path: f.session.rootPath) === f.session)
    #expect(!f.session.isScanning)
    #expect(f.session.tree === tree)
    c.cancel()
}

@Test @MainActor func stopReportsQueuedAdminItems() async throws {
    let f = try await fixture(3)
    let deleter = FakeDeleter { r, _ in r.path.hasSuffix("f0.bin") ? .needsAdmin(started: false) : .deleted(freed: r.size) }
    let admin = FakeAdmin { _ in "" }
    let clock = TestClock()
    let c = controller(f, deleter, admin: admin, clock: clock)
    deleter.after = { n in if n == 2 { await MainActor.run { c.cancel() } } }
    c.start()
    let report = try #require(await runToSummary(c, clock))
    #expect(admin.received.isEmpty)
    #expect(report.failed[f.paths[0]] == DeleteController.stoppedBeforeAdmin)
    #expect(collectedPaths(f) == [f.paths[0], f.paths[2]])
}

@MainActor private final class Flag { var value = false }

@Test @MainActor func trashSettingKey() {
    #expect(DeleteController.trashKey == "MoveToTrashInsteadOfDeleting")
}

@Test @MainActor func requestDeleteWaitsForConfirmation() async throws {
    let f = try await fixture(2)
    let deleter = FakeDeleter(), clock = TestClock()
    let c = controller(f, deleter, clock: clock)
    c.requestDelete()
    #expect(c.phase == .confirming)
    #expect(c.pendingCount == 2)
    #expect(!f.session.isDeleting)
    #expect(clock.sleeperCount == 0)   // no countdown yet
    try await Task.sleep(for: .milliseconds(50))
    #expect(deleter.calls.isEmpty)

    c.confirmDelete()
    #expect(c.phase == .countdown(remaining: 5))
    #expect(f.session.isDeleting)
    let report = try #require(await runToSummary(c, clock))
    #expect(report.deleted.count == 2)
}

@Test @MainActor func cancellingTheConfirmationDeletesNothing() async throws {
    let f = try await fixture(2)
    let deleter = FakeDeleter(), clock = TestClock()
    let c = controller(f, deleter, clock: clock)
    c.requestDelete()
    c.cancelConfirmation()
    #expect(c.phase == .idle)
    #expect(!f.session.isDeleting)
    #expect(collectedPaths(f) == f.paths.sorted())
    #expect(deleter.calls.isEmpty)
    // Nothing to confirm any more.
    c.confirmDelete()
    #expect(c.phase == .idle)
}

@Test @MainActor func cancelConfirmationLeavesARunningCountdownAlone() async throws {
    // The alert reports "dismissed" after its Delete button too: that must not cancel the countdown.
    let f = try await fixture(1)
    let deleter = FakeDeleter(), clock = TestClock()
    let c = controller(f, deleter, clock: clock)
    c.requestDelete()
    c.confirmDelete()
    c.cancelConfirmation()
    #expect(c.phase == .countdown(remaining: 5))
    c.cancel()
}

@Test @MainActor func requestDeleteNeedsCollectedItems() async throws {
    let f = try await fixture(1)
    f.session.uncollectAll()
    let c = controller(f, FakeDeleter(), clock: TestClock())
    c.requestDelete()
    #expect(c.phase == .idle)
}

@Test @MainActor func confirmCopyNamesWhatHappens() {
    let permanent = DeleteController.confirmCopy(count: 2, size: 1_500_000_000, mode: .permanent)
    #expect(permanent.title == "Delete 2 items (1.5 GB)?")
    #expect(permanent.message.contains("permanently"))
    let trash = DeleteController.confirmCopy(count: 1, size: 4096, mode: .trash)
    #expect(trash.title.hasPrefix("Move 1 item"))
    #expect(trash.message.contains("Trash"))
}
