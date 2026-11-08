import Foundation
import Testing
@testable import MacleanCore
import struct MacleanCore.Measurement
import MacleanKit
@testable import Maclean

// Fakes only: the deleter never touches disk. Engine runs use a fake home
// inside a Scratch folder, never the real one.

/// Probes with mutable answers (the owner can start between check and clean).
private final class Probes: CleanProbes, @unchecked Sendable {
    private let lock = NSLock()
    private var _running: Set<String> = []
    private var _unknown: Set<String> = []

    var running: Set<String> {
        get { lock.withLock { _running } }
        set { lock.withLock { _running = newValue } }
    }
    var unknown: Set<String> {
        get { lock.withLock { _unknown } }
        set { lock.withLock { _unknown = newValue } }
    }

    var now: Date { Date() }
    func isRunning(bundleID: String) -> Bool? {
        lock.withLock { _unknown.contains(bundleID) ? nil : _running.contains(bundleID) }
    }
    func isOpen(path: String) -> Bool? { false }
    func isProcessRunning(name: String) -> Bool? { false }
    func bundleID(appSupportFolder: String) -> String? { nil }
    func installedBundleIDs() -> Set<String>? { [] }
    func projectArtifacts(roots: [String]) -> [ProjectArtifact] { [] }
    func workingDirectories() -> [String]? { [] }
    func securityToolInstalled() -> Bool { false }
}

/// Records each request (with its mode) and answers from a script.
private final class Deletions: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(request: DeleteRequest, mode: DeleteMode, context: ProtectionContext)] = []
    let answer: @Sendable (DeleteRequest) -> DeleteOutcome

    init(_ answer: @escaping @Sendable (DeleteRequest) -> DeleteOutcome = { .deleted(freed: $0.size) }) {
        self.answer = answer
    }

    var calls: [(request: DeleteRequest, mode: DeleteMode, context: ProtectionContext)] { lock.withLock { _calls } }
    func add(_ r: DeleteRequest, _ m: DeleteMode, _ c: ProtectionContext) { lock.withLock { _calls.append((r, m, c)) } }

    func make(_ mode: DeleteMode, _ context: ProtectionContext) -> any DeleterProtocol {
        Recording(mode: mode, context: context, log: self)
    }

    private struct Recording: DeleterProtocol {
        let mode: DeleteMode
        let context: ProtectionContext
        let log: Deletions
        func delete(_ r: DeleteRequest, force: Bool) async -> DeleteOutcome {
            log.add(r, mode, context)
            return log.answer(r)
        }
    }
}

private final class Admin: AdminRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _arguments: [[String]] = []
    private let answer: @Sendable ([String]) throws -> String
    init(_ answer: @escaping @Sendable ([String]) throws -> String = { _ in "" }) { self.answer = answer }
    var arguments: [[String]] { lock.withLock { _arguments } }
    func run(_ arguments: [String]) async throws -> String {
        lock.withLock { _arguments.append(arguments) }
        return try answer(arguments)
    }
}

/// A flag the `scanning` closure reads.
@MainActor private final class Flag { var value = false }

private func measurement(size: Int64 = 1000, inode: UInt64 = 7, device: Int32 = 3) -> Measurement {
    Measurement(size: size, fileCount: 2, newest: Date(timeIntervalSince1970: 1_700_000_000), inode: inode,
                device: device, isDirectory: true, restricted: false)
}

private func candidate(_ path: String, category: CleanRule.Category = .appCaches, tier: CleanRule.Tier = .safe,
                       measured: Bool = true, admin: Bool = false, owner: String? = nil,
                       m: Measurement = measurement()) -> CleanCandidate {
    CleanCandidate(path: path, ruleID: "r", category: category, tier: tier, displayName: path, reason: "test",
                   measurement: measured ? m : nil, requiresAdmin: admin, owner: owner)
}

private func defaults() -> UserDefaults {
    UserDefaults(suiteName: "maclean-tests-\(UUID().uuidString)")!
}

/// A fake home with one old-enough cache folder per name in `caches`.
private final class Home {
    let scratch = Scratch()
    var path: String { scratch.path + "/home" }
    init(caches: [String] = ["a", "b"]) {
        for name in caches { scratch.file("home/Library/Caches/\(name)/x.bin", bytes: 4096) }
    }
    func cache(_ name: String) -> String { path + "/Library/Caches/" + name }

    func engine(probes: Probes) -> CleanEngine {
        let rule = CleanRule(id: "caches", category: .appCaches, pattern: "~/Library/Caches", unit: .eachChild,
                             ageTiers: [(0, .safe)], reason: "test")
        return CleanEngine(rules: [rule], home: path,
                           environment: ProtectionEnvironment(home: path, appBundle: "/Applications/Maclean.app",
                                                              mountPoints: ["/"], timeMachineMounts: []),
                           probes: probes)
    }
}

@MainActor private func controller(home: Home = Home(caches: []), probes: Probes = Probes(),
                                   deletions: Deletions = Deletions(), admin: Admin = Admin(),
                                   defaults: UserDefaults = defaults(),
                                   scanning: @escaping (Int32) -> Bool = { _ in false }) -> SmartCleanController {
    SmartCleanController(engine: { home.engine(probes: probes) }, probes: probes,
                         makeDeleter: { deletions.make($0, $1) }, admin: admin, defaults: defaults,
                         scanning: scanning)
}

@MainActor private func until(_ condition: () -> Bool) async {
    for _ in 0..<2000 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
}

@MainActor private func summary(_ c: SmartCleanController) -> DeleteReport? {
    if case .summary(let r) = c.phase { return r }
    return nil
}

// MARK: - Selection

@Test @MainActor func defaultSelectionIsSafeWithKnownSize() {
    let c = controller()
    c.publish(CleanReport(candidates: [
        candidate("/x/safe", m: measurement(size: 100)),
        candidate("/x/review", tier: .review, m: measurement(size: 20)),
        candidate("/x/info", tier: .info, m: measurement(size: 5000)),
        candidate("/x/unknown", tier: .review, measured: false, admin: true),
    ]))
    #expect(c.phase == .ready)
    #expect(c.selected == ["/x/safe"])
    #expect(c.selectedSize == 100)
    #expect(c.foundSize == 120)
    #expect(!c.needsAdmin)
    // Info and size-unknown rows can't be selected.
    c.selected = ["/x/safe", "/x/review", "/x/info", "/x/unknown"]
    #expect(c.selectedSize == 120)
    #expect(!c.needsAdmin)
}

@Test @MainActor func nothingFoundPhase() {
    let c = controller()
    c.publish(CleanReport())
    #expect(c.phase == .nothingFound)
}

// MARK: - Clean

@Test @MainActor func ownerOpenAtCleanSkipsItem() async throws {
    let probes = Probes(), deletions = Deletions()
    let c = controller(probes: probes, deletions: deletions)
    c.publish(CleanReport(candidates: [
        candidate("/x/owned", owner: "com.acme.Example"),
        candidate("/x/unknown", owner: "com.acme.Other"),
        candidate("/x/free"),
    ]))
    probes.running = ["com.acme.Example"]
    probes.unknown = ["com.acme.Other"]
    await c.clean()
    let report = try #require(summary(c))
    #expect(report.failed["/x/owned"] == "Example is open.")
    #expect(report.failed["/x/unknown"] == "Other is open.")
    #expect(report.deleted == ["/x/free"])
    #expect(deletions.calls.map(\.request.path) == ["/x/free"])
}

@Test @MainActor func safeCacheUsesCacheTolerance() async {
    let deletions = Deletions()
    let c = controller(deletions: deletions)
    c.publish(CleanReport(candidates: [
        candidate("/x/cache", m: measurement(size: 10, inode: 11, device: 4)),
        candidate("/x/log", category: .systemLogs),
        candidate("/x/reviewCache", tier: .review),
        candidate("/x/leftover", category: .removedApps),
    ]))
    c.selected = ["/x/cache", "/x/log", "/x/reviewCache", "/x/leftover"]
    await c.clean()
    let byPath = Dictionary(uniqueKeysWithValues: deletions.calls.map { ($0.request.path, $0.request) })
    #expect(byPath["/x/cache"]?.tolerance == .cache)
    #expect(byPath["/x/log"]?.tolerance == .cache)
    #expect(byPath["/x/reviewCache"]?.tolerance == .strict)
    #expect(byPath["/x/leftover"]?.tolerance == .strict)
    // The request carries the check's identity and size.
    #expect(byPath["/x/cache"] == DeleteRequest(path: "/x/cache", inode: 11, device: 4, size: 10, fileCount: 2,
                                                isDirectory: true, tolerance: .cache))
    #expect(deletions.calls.allSatisfy { $0.context == .smartClean })
}

@Test @MainActor func trashCategoryAlwaysPermanent() async {
    let deletions = Deletions(), d = defaults()
    d.set(true, forKey: DeleteController.trashKey)
    let c = controller(deletions: deletions, defaults: d)
    c.publish(CleanReport(candidates: [candidate("/x/trash", category: .trash), candidate("/x/cache")]))
    c.selected = ["/x/trash", "/x/cache"]
    await c.clean()
    let modes = Dictionary(uniqueKeysWithValues: deletions.calls.map { ($0.request.path, $0.mode) })
    #expect(modes["/x/trash"] == .permanent)
    #expect(modes["/x/cache"] == .trash)
}

@Test @MainActor func cancelledPromptSkipsOnlySystemItems() async throws {
    let deletions = Deletions { $0.path == "/Library/Logs/sys" ? .needsAdmin(started: false) : .deleted(freed: $0.size) }
    let c = controller(deletions: deletions, admin: Admin { _ in throw AdminRunnerError.cancelled })
    c.publish(CleanReport(candidates: [candidate("/Library/Logs/sys", category: .systemLogs, admin: true),
                                       candidate("/x/user")]))
    #expect(c.needsAdmin)
    await c.clean()
    let report = try #require(summary(c))
    #expect(report.failed["/Library/Logs/sys"] == DeleteBatch.adminNotGiven)
    #expect(report.deleted == ["/x/user"])
}

@Test @MainActor func deletedPathsMarkedRemovedInSessions() async throws {
    let s = Scratch()
    s.file("Caches/a/x.bin", bytes: 8192)
    s.file("Caches/b/y.bin", bytes: 4096)
    let registry = SessionRegistry()
    registry.onFinish = { _, _ in }
    let session = registry.startScan(path: s.path)
    await until { !session.isScanning }
    let tree = try #require(session.tree)
    let a = s.path + "/Caches/a", b = s.path + "/Caches/b"
    let aNode = try #require(tree.node(atPath: a)), bNode = try #require(tree.node(atPath: b))
    let caches = try #require(tree.node(atPath: s.path + "/Caches"))
    let before = try #require(session.view).size(of: caches)

    let c = controller()
    c.registry = registry
    c.publish(CleanReport(candidates: [
        candidate(a, m: measurement(size: tree.size(of: aNode), inode: tree.inode(of: aNode), device: tree.device(of: aNode))),
        // Same path, different identity: not marked.
        candidate(b, m: measurement(size: 1, inode: tree.inode(of: bNode) + 1, device: tree.device(of: bNode))),
    ]))
    await c.clean()
    #expect(summary(c)?.deleted.sorted() == [a, b])
    let view = try #require(session.view)
    #expect(view.removed == [aNode])
    #expect(view.isHidden(aNode))
    #expect(view.size(of: caches) == before - tree.size(of: aNode))
}

@Test @MainActor func cleanRechecksAndDismissShowsResult() async throws {
    let home = Home(caches: ["a"])
    let c = controller(home: home)
    c.publish(CleanReport(candidates: [candidate("/x/old")]))
    await c.clean()
    #expect(summary(c) != nil)
    // The background re-check replaces the report without leaving the summary.
    await until { c.report?.candidates.map(\.path) == [home.cache("a")] }
    #expect(summary(c) != nil)
    c.dismissSummary()
    #expect(c.phase == .ready)
}

// MARK: - Check

@Test @MainActor func checkWaitsWhileVolumeScanning() async throws {
    let home = Home(caches: ["a"])
    let flag = Flag()
    flag.value = true
    let c = controller(home: home, scanning: { _ in flag.value })
    c.check()
    #expect(c.phase == .checking)
    try await Task.sleep(for: .milliseconds(700))
    #expect(c.phase == .checking)
    #expect(c.report == nil)
    flag.value = false
    await until { c.phase == .ready }
    #expect(c.phase == .ready)
    #expect(c.report?.candidates.map(\.path) == [home.cache("a")])
    #expect(c.selected == [home.cache("a")])
}

@Test @MainActor func cancelledCheckPublishesNothing() async throws {
    let home = Home(caches: ["a"])
    let flag = Flag()
    flag.value = true
    let c = controller(home: home, scanning: { _ in flag.value })
    c.check()
    try await Task.sleep(for: .milliseconds(100))
    c.cancelCheck()
    #expect(c.phase == .idle)
    flag.value = false
    try await Task.sleep(for: .milliseconds(800))
    #expect(c.phase == .idle)
    #expect(c.report == nil)
}

@Test @MainActor func isCheckingTracksCheckAndCancel() async throws {
    let home = Home(caches: ["a"])
    let flag = Flag()
    flag.value = true
    let c = controller(home: home, scanning: { _ in flag.value })
    #expect(!c.isChecking)
    c.check()
    #expect(c.isChecking)
    try await Task.sleep(for: .milliseconds(100))
    c.cancelCheck()
    #expect(!c.isChecking)
    flag.value = false
    c.check()
    #expect(c.isChecking)
    await until { c.phase == .ready }
    #expect(!c.isChecking)
}

@Test @MainActor func lastModeIsCapturedAtCleanStart() async {
    let home = Home(caches: ["a"])
    let d = defaults()
    d.set(true, forKey: DeleteController.trashKey)
    let c = controller(home: home, defaults: d)
    c.check()
    await until { c.phase == .ready }
    await c.clean()
    d.set(false, forKey: DeleteController.trashKey)
    #expect(c.lastMode == .trash)
}

@Test @MainActor func launchCheckRespectsSetting() async {
    let home = Home(caches: ["a"])
    let off = defaults()
    off.set(false, forKey: SmartCleanController.checkAtLaunchKey)
    let c = controller(home: home, defaults: off)
    c.checkAtLaunchIfEnabled()
    #expect(c.phase == .idle)
    // Default on.
    let on = controller(home: home)
    on.checkAtLaunchIfEnabled()
    await until { on.phase == .ready }
    #expect(on.phase == .ready)
}

@Test @MainActor func neverCleanPersistsAndRechecks() async throws {
    let home = Home(caches: ["a", "b"])
    let d = defaults()
    let c = controller(home: home, defaults: d)
    c.check()
    await until { c.phase == .ready }
    #expect(c.report?.candidates.map(\.path) == [home.cache("a"), home.cache("b")])
    c.neverClean(home.cache("a"))
    #expect(d.stringArray(forKey: SmartCleanController.neverCleanKey) == [home.cache("a")])
    await until { c.phase == .ready && c.report?.candidates.count == 1 }
    #expect(c.report?.candidates.map(\.path) == [home.cache("b")])
    #expect(c.report?.skipped.contains(SkippedItem(path: home.cache("a"), reason: .neverClean)) == true)
    // Not added twice.
    c.neverClean(home.cache("a"))
    #expect(d.stringArray(forKey: SmartCleanController.neverCleanKey) == [home.cache("a")])
}

@Test @MainActor func disabledCategoryFromSettings() async {
    let home = Home(caches: ["a"])
    let d = defaults()
    d.set([CleanRule.Category.appCaches.rawValue], forKey: SmartCleanController.disabledCategoriesKey)
    let c = controller(home: home, defaults: d)
    c.check()
    await until { c.phase == .nothingFound }
    #expect(c.report?.skipped.map(\.reason) == [.categoryOff])
}

// MARK: - Measure with administrator rights

@Test @MainActor func measureWithAdminFillsSizeUnknownRows() async throws {
    let filled = measurement(size: 777, inode: 9, device: 2)
    let admin = Admin { args in
        // The paths file exists only during the run.
        let i = try #require(args.firstIndex(of: "--paths-file"))
        let paths = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: args[i + 1])))
        #expect(paths == ["/Library/Caches/a", "/Library/Caches/b"])
        return [AdminMeasure.encode(.init(path: "/Library/Caches/a", measurement: filled, error: nil)),
                AdminMeasure.encode(.init(path: "/Library/Caches/b", measurement: nil, error: "unreadable"))]
            .joined(separator: "\n")
    }
    let c = controller(admin: admin)
    c.publish(CleanReport(candidates: [
        candidate("/Library/Caches/a", category: .systemCaches, tier: .review, measured: false, admin: true),
        candidate("/Library/Caches/b", category: .systemCaches, tier: .review, measured: false, admin: true),
        candidate("/x/user", measured: false),
    ]))
    await c.measureWithAdmin()
    #expect(admin.arguments.count == 1)
    #expect(admin.arguments.first?.first == "smart-measure")
    let rows = Dictionary(uniqueKeysWithValues: (c.report?.candidates ?? []).map { ($0.path, $0) })
    #expect(rows["/Library/Caches/a"]?.measurement == filled)
    #expect(rows["/Library/Caches/b"]?.measurement == nil)
    #expect(rows["/x/user"]?.measurement == nil)
    // Measured, but still unticked; now selectable.
    #expect(!c.selected.contains("/Library/Caches/a"))
    c.selected.insert("/Library/Caches/a")
    #expect(c.selectedSize == 777)
    // The paths file is removed.
    let i = try #require(admin.arguments.first?.firstIndex(of: "--paths-file"))
    #expect(!FileManager.default.fileExists(atPath: admin.arguments[0][i + 1]))
}

@Test @MainActor func measureWithAdminCancelledKeepsRows() async {
    let c = controller(admin: Admin { _ in throw AdminRunnerError.cancelled })
    c.publish(CleanReport(candidates: [candidate("/Library/Caches/a", category: .systemCaches, tier: .review,
                                                 measured: false, admin: true)]))
    await c.measureWithAdmin()
    #expect(c.report?.candidates.first?.measurement == nil)
    #expect(c.phase == .ready)
}

// MARK: - Pausing target device

@Test func targetDeviceUsesLiteralPrefix() {
    let s = Scratch()
    s.file("home/Library/Caches/a/x", bytes: 1)
    var st = stat()
    stat(s.path, &st)
    #expect(SmartCleanController.targetDevice(pattern: "~/Library/Caches/*/x", home: s.path + "/home") == st.st_dev)
    #expect(SmartCleanController.targetDevice(pattern: "~/Nope/{a,b}", home: s.path + "/home") == st.st_dev)
    #expect(SmartCleanController.targetDevice(pattern: "", home: s.path + "/home") == st.st_dev)
}
