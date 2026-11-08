import Foundation
import Testing
@testable import MacleanCore
import struct MacleanCore.Measurement
import MacleanKit
@testable import Maclean

// Fakes only: no real administrator dialog. "Root" is simulated by briefly
// opening the locked TempDir folders to this user, scanning them and writing
// real tree archives into the out dir the session made.

/// A scratch folder with `locked` subfolders this user can't open (mode 000),
/// each holding one file, plus an open folder.
private final class Locked {
    let scratch = Scratch()
    let names: [String]
    var path: String { scratch.path }

    init(_ names: [String] = ["p", "q"]) {
        self.names = names
        scratch.file("open/o.bin", bytes: 4096)
        for name in names {
            scratch.file("\(name)/inner/x.bin", bytes: 64 * 1024)
            chmod(scratch.path + "/" + name, 0)
        }
    }

    deinit { for name in names { chmod(scratch.path + "/" + name, 0o755) } }
}

/// Plays root: answers `read-restricted` by scanning each listed folder
/// (opened for the moment) into `outDir/<index>.mtree`, failing the paths in
/// `failing`; answers `smart-measure` with `measured` for every path.
private final class Root: AdminFake, @unchecked Sendable {
    private let lock = NSLock()
    private var _arguments: [[String]] = []
    private var _requests: [AdminRead.Request] = []
    let failing: Set<String>
    let cancel: Bool
    let measured: Measurement

    init(failing: Set<String> = [], cancel: Bool = false, measured: Measurement = adminMeasurement) {
        self.failing = failing
        self.cancel = cancel
        self.measured = measured
    }

    var arguments: [[String]] { lock.withLock { _arguments } }
    /// Each `read-restricted` request, parsed while its paths file existed.
    var requests: [AdminRead.Request] { lock.withLock { _requests } }

    override func runOne(_ arguments: [String]) async throws -> String {
        lock.withLock { _arguments.append(arguments) }
        if cancel { throw AdminRunnerError.cancelled }
        if arguments.first == "smart-measure" {
            let i = arguments.firstIndex(of: "--paths-file")!
            let paths = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[i + 1])))
            return paths.map { AdminMeasure.encode(.init(path: $0, measurement: measured, error: nil)) }
                .joined(separator: "\n")
        }
        let request = try AdminRead.parse(arguments)
        lock.withLock { _requests.append(request) }
        var lines: [String] = []
        for (index, path) in request.paths.enumerated() {
            if failing.contains(path) {
                lines.append(AdminRead.encode(.init(path: path, file: nil, error: "unreadable")))
                continue
            }
            chmod(path, 0o755)
            let tree = try await Scanner.scan(path: path, boundary: ScanBoundary.forRoot(request.root))
            chmod(path, 0)
            let file = request.outDir + "/\(index).mtree"
            try TreeArchive.write(tree, to: URL(fileURLWithPath: file))
            lines.append(AdminRead.encode(.init(path: path, file: file, error: nil)))
        }
        return lines.joined(separator: "\n")
    }
}

private let adminMeasurement = Measurement(size: 777, fileCount: 2, newest: Date(timeIntervalSince1970: 1_700_000_000),
                                           inode: 9, device: 2, isDirectory: true, restricted: false)

private func defaults(ask: Bool? = nil) -> UserDefaults {
    let d = UserDefaults(suiteName: "maclean-tests-\(UUID().uuidString)")!
    if let ask { d.set(ask, forKey: AdminBatcher.askKey) }
    return d
}

@MainActor private func until(_ condition: () -> Bool) async {
    for _ in 0..<2000 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
}

@MainActor private func makeRegistry(_ root: Root, defaults: UserDefaults = defaults(),
                                 coordinator: PromptCoordinator = PromptCoordinator(hasAccess: { true })) -> SessionRegistry {
    let registry = SessionRegistry()
    registry.defaults = defaults
    registry.batcher = AdminBatcher(runner: root, coordinator: coordinator)
    return registry
}

private let readReason2 = "Maclean needs to read 2 folders that only an administrator can open."

@Test @MainActor func scanAsksOnceAndGrafts() async throws {
    let locked = Locked()
    let root = Root()
    let registry = makeRegistry(root)
    let session = registry.startScan(path: locked.path)
    await until { !session.isScanning && session.restrictedCount == 0 && session.stillNeedsAccessCount != nil }

    #expect(root.prompts == [readReason2])
    // Only the two locked folders were sent.
    let request = try #require(root.requests.first)
    #expect(Set(request.paths) == [locked.path + "/p", locked.path + "/q"])
    #expect(request.root == locked.path)
    // The out dir and paths file are gone.
    #expect(!FileManager.default.fileExists(atPath: request.outDir))
    let args = try #require(root.arguments.first)
    let flag = try #require(args.firstIndex(of: "--paths-file"))
    let file = args[flag + 1]
    #expect(!FileManager.default.fileExists(atPath: file))

    let tree = try #require(session.tree)
    let x = try #require(tree.node(atPath: locked.path + "/p/inner/x.bin"))
    #expect(tree.size(of: x) >= 64 * 1024)
    #expect(session.view?.tree === tree)
    #expect(session.restrictedCount == 0)
    #expect(session.stillNeedsAccessCount == 0)

    try? await Task.sleep(for: .milliseconds(100))
    #expect(root.prompts.count == 1)
}

@Test @MainActor func graftCarriesCollectedItemsOver() async throws {
    let locked = Locked(["p"])
    let session = ScanSession(rootPath: locked.path)
    session.start()
    await until { !session.isScanning }
    let before = try #require(session.tree)
    let open = try #require(before.node(atPath: locked.path + "/open"))
    session.collect([open])

    let root = Root()
    await session.readRestricted(using: AdminBatcher(runner: root, coordinator: PromptCoordinator(hasAccess: { true })))
    let tree = try #require(session.tree)
    #expect(tree !== before)
    let view = try #require(session.view)
    #expect(view.tree === tree)
    #expect(view.collected.map { tree.path(of: $0) } == [locked.path + "/open"])
}

@Test @MainActor func scanCancelLeavesTreeAndNoReask() async throws {
    let locked = Locked()
    let root = Root(cancel: true)
    let registry = makeRegistry(root)
    let session = registry.startScan(path: locked.path)
    await until { !session.isScanning }
    let before = try #require(session.tree)
    await until { root.prompts.count == 1 && !session.isReadingRestricted }

    #expect(session.tree === before)
    #expect(session.restrictedCount == 2)
    #expect(session.stillNeedsAccessCount == nil)
    try? await Task.sleep(for: .milliseconds(150))
    #expect(root.prompts.count == 1)
}

@Test @MainActor func settingOffNeverAsks() async throws {
    let locked = Locked()
    let root = Root()
    let registry = makeRegistry(root, defaults: defaults(ask: false))
    let session = registry.startScan(path: locked.path)
    await until { !session.isScanning }
    try? await Task.sleep(for: .milliseconds(150))
    #expect(root.prompts.isEmpty)
    #expect(session.restrictedCount == 2)
}

@Test @MainActor func stillNeedsAccessCounted() async throws {
    let locked = Locked()
    let root = Root(failing: [locked.path + "/q"])
    let registry = makeRegistry(root)
    let session = registry.startScan(path: locked.path)
    await until { !session.isScanning && session.stillNeedsAccessCount != nil }

    #expect(session.stillNeedsAccessCount == 1)
    #expect(session.restrictedCount == 1)
    let tree = try #require(session.tree)
    #expect(tree.node(atPath: locked.path + "/p/inner/x.bin") != nil)
    #expect(tree.flags(of: try #require(tree.node(atPath: locked.path + "/q"))).contains(.restricted))
}

// MARK: - Rescans and forgotten sessions

@Test @MainActor func rescanAsksAgainOnce() async throws {
    let locked = Locked()
    let root = Root()
    let registry = makeRegistry(root)
    let session = registry.startScan(path: locked.path)
    await until { !session.isScanning && session.stillNeedsAccessCount != nil }
    #expect(root.prompts == [readReason2])

    registry.rescan(canonical: locked.path)
    await until { !session.isScanning && root.prompts.count == 2 && session.stillNeedsAccessCount != nil
        && !session.isReadingRestricted }
    #expect(root.prompts == [readReason2, readReason2])
    #expect(session.restrictedCount == 0)
    try? await Task.sleep(for: .milliseconds(150))
    #expect(root.prompts.count == 2)
}

@Test @MainActor func rescanWhileReadQueuedStillAsksOnceForNewTree() async throws {
    let locked = Locked()
    let root = Root()
    let coordinator = PromptCoordinator(hasAccess: { false })
    coordinator.launch()   // the sheet holds every admin job back
    let registry = makeRegistry(root, coordinator: coordinator)
    let batcher = try #require(registry.batcher)
    let session = registry.startScan(path: locked.path)
    await until { batcher.pendingCount == 1 }

    registry.rescan(canonical: locked.path)
    await until { !session.isScanning && batcher.pendingCount == 2 }
    let newTree = try #require(session.tree)
    #expect(session.isReadingRestricted)

    coordinator.continueWithoutAccess()
    await until { session.stillNeedsAccessCount != nil && !session.isReadingRestricted }
    // The stale read gave way: one dialog, one invocation, for the new tree.
    #expect(root.prompts == [readReason2])
    #expect(root.requests.count == 1)
    #expect(session.restrictedCount == 0)
    #expect(session.tree !== newTree)
    #expect(session.tree?.node(atPath: locked.path + "/q/inner/x.bin") != nil)
}

@Test @MainActor func forgottenSessionNeverPrompts() async throws {
    let locked = Locked()
    let root = Root()
    let coordinator = PromptCoordinator(hasAccess: { false })
    coordinator.launch()
    let registry = makeRegistry(root, coordinator: coordinator)
    let batcher = try #require(registry.batcher)
    let session = registry.startScan(path: locked.path)
    await until { batcher.pendingCount == 1 }

    registry.forget(path: locked.path)
    coordinator.continueWithoutAccess()
    await until { !session.isReadingRestricted }
    try? await Task.sleep(for: .milliseconds(150))
    #expect(root.prompts.isEmpty)

    // Asked by hand later, a forgotten session doesn't submit at all.
    await session.readRestricted(using: batcher)
    #expect(batcher.pendingCount == 0)
    #expect(root.prompts.isEmpty)
}

@Test @MainActor func readReasonCountsWhatIsSent() {
    #expect(ScanSession.readPrompt(count: 3) == "Maclean needs to read 3 folders that only an administrator can open.")
}

// MARK: - Smart Clean

/// Probes that answer "nothing open, nothing running".
private struct NoProbes: CleanProbes {
    var now: Date { Date() }
    func isRunning(bundleID: String) -> Bool? { false }
    func isOpen(path: String) -> Bool? { false }
    func isProcessRunning(name: String) -> Bool? { false }
    func bundleID(appSupportFolder: String) -> String? { nil }
    func installedBundleIDs() -> Set<String>? { [] }
    func projectArtifacts(roots: [String]) -> [ProjectArtifact] { [] }
    func workingDirectories() -> [String]? { [] }
    func securityToolInstalled() -> Bool { false }
    func hasFullDiskAccess() -> Bool { true }
}

/// Never touches disk.
private struct NoDeleter: DeleterProtocol {
    func delete(_ r: DeleteRequest, force: Bool) async -> DeleteOutcome { .deleted(freed: 0) }
}

/// A fake home with one ordinary cache (Safe, measurable) and one system log
/// folder this user can't open (needs administrator rights, size unknown).
private final class SystemHome {
    let scratch = Scratch()
    var path: String { scratch.path + "/home" }
    var log: String { path + "/Library/Logs/sys" }

    init() {
        scratch.file("home/Library/Caches/c/x.bin", bytes: 4096)
        scratch.file("home/Library/Logs/sys/x.log", bytes: 4096)
        chmod(log, 0)
    }

    deinit { chmod(log, 0o755) }

    func engine() -> CleanEngine {
        let caches = CleanRule(id: "caches", category: .appCaches, pattern: "~/Library/Caches", unit: .eachChild,
                               ageTiers: [(0, .safe)], reason: "test")
        let logs = CleanRule(id: "logs", category: .systemLogs, pattern: "~/Library/Logs", unit: .eachChild,
                             ageTiers: [(0, .review)], requiresAdmin: true, reason: "test")
        return CleanEngine(rules: [caches, logs], home: path,
                           environment: ProtectionEnvironment(home: path, appBundle: "/Applications/Maclean.app",
                                                              mountPoints: ["/"], timeMachineMounts: []),
                           probes: NoProbes())
    }
}

@MainActor private func smartClean(_ root: Root, batcher: AdminBatcher, home: SystemHome? = nil,
                                   defaults: UserDefaults = defaults()) -> SmartCleanController {
    let engine: () -> CleanEngine = home.map { h in { h.engine() } }
        ?? { CleanEngine(rules: [], home: "/nonexistent", environment: .current(), probes: NoProbes()) }
    return SmartCleanController(engine: engine, probes: NoProbes(), makeDeleter: { _, _ in NoDeleter() },
                                admin: root, batcher: batcher, defaults: defaults,
                                notifications: NotificationCenter(), scanning: { _ in false })
}

@MainActor private func freeBatcher(_ root: Root) -> AdminBatcher {
    AdminBatcher(runner: root, coordinator: PromptCoordinator(hasAccess: { true }))
}

private func unknownAdminReport() -> CleanReport {
    CleanReport(candidates: [CleanCandidate(path: "/Library/Caches/a", ruleID: "r", category: .systemCaches,
                                            tier: .review, displayName: "a", reason: "test", measurement: nil,
                                            requiresAdmin: true, owner: nil)])
}

@MainActor private func logRow(_ c: SmartCleanController, _ home: SystemHome) -> CleanCandidate? {
    c.report?.candidates.first { $0.path == home.log }
}

private let measureReason1 = "Maclean needs to measure 1 system items for Smart Clean."

@Test @MainActor func smartCleanAutoMeasuresOnceAfterCheck() async throws {
    let home = SystemHome()
    let root = Root()
    let c = smartClean(root, batcher: freeBatcher(root), home: home)
    c.check(userInitiated: true)
    await until { logRow(c, home)?.measurement != nil }
    #expect(root.prompts == [measureReason1])
    #expect(logRow(c, home)?.measurement == adminMeasurement)
}

@Test @MainActor func smartCleanPostCleanRecheckNeverPrompts() async throws {
    let home = SystemHome()
    let root = Root()
    let c = smartClean(root, batcher: freeBatcher(root), home: home)
    c.check(userInitiated: true)
    await until { logRow(c, home)?.measurement != nil && !c.awaitingAdmin }
    #expect(root.prompts.count == 1)
    #expect(c.chosenCount == 1)   // the ordinary cache; the measured log stays unticked

    await c.clean()
    c.dismissSummary()   // the re-check is still running, so its result publishes into .ready
    await until { !c.isChecking && c.phase == .ready }
    #expect(logRow(c, home)?.measurement == nil)   // the re-check found it size unknown again
    try? await Task.sleep(for: .milliseconds(150))
    #expect(root.prompts.count == 1)
}

@Test @MainActor func smartCleanCancelThenUserCheckAsksAgain() async throws {
    let home = SystemHome()
    let root = Root(cancel: true)
    let c = smartClean(root, batcher: freeBatcher(root), home: home)
    c.check(userInitiated: true)
    await until { root.prompts.count == 1 && !c.awaitingAdmin }
    #expect(logRow(c, home)?.measurement == nil)

    // A background re-check doesn't ask again.
    c.check()
    await until { !c.isChecking }
    try? await Task.sleep(for: .milliseconds(150))
    #expect(root.prompts.count == 1)

    // ⇧⌘K does.
    c.check(userInitiated: true)
    await until { root.prompts.count == 2 && !c.awaitingAdmin }
    #expect(root.prompts == [measureReason1, measureReason1])
    #expect(c.phase == .ready)
}

@Test @MainActor func smartCleanSettingOffNeverMeasures() async throws {
    let home = SystemHome()
    let root = Root()
    let c = smartClean(root, batcher: freeBatcher(root), home: home, defaults: defaults(ask: false))
    c.check(userInitiated: true)
    await until { !c.isChecking }
    try? await Task.sleep(for: .milliseconds(150))
    #expect(logRow(c, home) != nil)
    #expect(root.prompts.isEmpty)
}

@Test @MainActor func scanReadAndMeasureShareOneDialog() async throws {
    let locked = Locked()
    let session = ScanSession(rootPath: locked.path)
    session.start()
    await until { !session.isScanning }

    // The Full Disk Access sheet is up, so both jobs wait for it.
    let coordinator = PromptCoordinator(hasAccess: { false })
    coordinator.launch()
    let root = Root()
    let batcher = AdminBatcher(runner: root, coordinator: coordinator)
    let c = smartClean(root, batcher: batcher)
    c.publish(unknownAdminReport(), autoMeasure: true)
    let read = Task { await session.readRestricted(using: batcher) }
    await until { batcher.pendingCount == 2 }
    #expect(root.prompts.isEmpty)

    coordinator.continueWithoutAccess()
    await read.value
    await until { c.report?.candidates.first?.measurement != nil }

    #expect(root.prompts.count == 1)
    let prompt = try #require(root.prompts.first)
    #expect(prompt.contains(measureReason1))
    #expect(prompt.contains(readReason2))
    #expect(root.arguments.count == 2)
    #expect(session.restrictedCount == 0)
}

/// A measure superseded (a new check) while waiting for its dialog is dropped
/// by the batcher: no dialog at all.
@Test @MainActor func supersededMeasureNeverShowsDialog() async throws {
    let coordinator = PromptCoordinator(hasAccess: { false })
    coordinator.launch()   // the access sheet holds the batcher
    let root = Root()
    let batcher = AdminBatcher(runner: root, coordinator: coordinator)
    let c = smartClean(root, batcher: batcher)
    c.publish(unknownAdminReport(), autoMeasure: true)
    await until { batcher.pendingCount == 1 }
    c.check()   // supersedes the measure
    await until { !c.isChecking }
    coordinator.continueWithoutAccess()
    await until { batcher.pendingCount == 0 }
    try? await Task.sleep(for: .milliseconds(100))
    #expect(root.prompts.isEmpty)
    #expect(root.arguments.isEmpty)
}
