import Darwin
import Foundation
import MacleanCore
import Observation

/// Smart Clean (spec §5): runs the check in the background, holds the found
/// items and the user's ticks, and deletes the ticked items through the shared
/// `DeleteBatch` after the view's confirmation alert.
///
/// The check pauses between targets while a scan of the target's volume runs,
/// never asks for a password and never deletes. A cancelled check publishes
/// nothing.
@MainActor @Observable final class SmartCleanController {
    enum Phase: Equatable {
        case idle, checking, ready, nothingFound, confirming
        case cleaning(done: Int, total: Int)
        case summary(DeleteReport)
    }

    static let checkAtLaunchKey = "smartClean.checkAtLaunch"
    static let neverCleanKey = "smartClean.neverClean"
    /// The administrator dialog's reason for measuring `count` system items.
    static func measurePrompt(count: Int) -> String {
        "Maclean needs to measure \(count) system items for Smart Clean."
    }
    static let disabledCategoriesKey = "smartClean.disabledCategories"
    static let projectRootsKey = "smartClean.projectRoots"
    /// How often a paused check asks whether the scan is still running.
    static let pollInterval: Duration = .milliseconds(500)
    /// Categories whose Safe items may have changed a little since the check (spec §6.3, R5).
    static let cacheCategories: Set<CleanRule.Category> = [.appCaches, .browsers, .logs, .systemLogs, .systemCaches]

    private(set) var phase: Phase = .idle
    private(set) var report: CleanReport?
    /// Ticked paths. Defaults: Safe items with a known size.
    var selected: Set<String> = []
    /// True while the administrator prompt (and the helper) runs, during a
    /// clean or "Measure with administrator rights".
    var awaitingAdmin: Bool { (batch?.awaitingAdmin ?? false) || measuring }
    /// True while a check runs (also behind the summary). Observed, unlike `checkTask`.
    private(set) var isChecking = false

    /// True from the confirmation alert until the summary is dismissed.
    var isBusyCleaning: Bool {
        switch phase {
        case .confirming, .cleaning, .summary: true
        default: false
        }
    }

    private var batch: DeleteBatch?
    private var measuring = false

    /// Called for every engine run: production builds a fresh `LiveCleanProbes` each time.
    @ObservationIgnored private let makeEngine: () -> CleanEngine
    /// Re-asked just before each item is deleted.
    @ObservationIgnored private let probes: any CleanProbes
    @ObservationIgnored private let makeDeleter: (DeleteMode, ProtectionContext) -> any DeleterProtocol
    @ObservationIgnored private let admin: any AdminRunning
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let scanning: (Int32) -> Bool
    /// Where `.macleanDidDelete` is posted after a clean that deleted something.
    @ObservationIgnored private let notifications: NotificationCenter
    @ObservationIgnored private var checkTask: Task<CleanReport, Never>?
    /// Bumped by every check start, cancel and admin measure, so stale results are dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var stopRequested = false
    /// Open scan results, updated after a clean (spec §5.3).
    @ObservationIgnored weak var registry: SessionRegistry?

    init(engine: @escaping () -> CleanEngine, probes: any CleanProbes,
         makeDeleter: @escaping (DeleteMode, ProtectionContext) -> any DeleterProtocol, admin: any AdminRunning,
         defaults: UserDefaults = .standard, notifications: NotificationCenter = .default,
         scanning: @escaping (Int32) -> Bool) {
        makeEngine = engine
        self.probes = probes
        self.makeDeleter = makeDeleter
        self.admin = admin
        self.defaults = defaults
        self.scanning = scanning
        self.notifications = notifications
    }

    // MARK: Selection

    private var selectable: [CleanCandidate] {
        (report?.candidates ?? []).filter(Self.isSelectable)
    }

    /// Ticked items that can be cleaned (known size, not Info).
    private var chosen: [CleanCandidate] { selectable.filter { selected.contains($0.path) } }

    /// How many ticked items Clean would delete (the alert's count; same set as `selectedSize`).
    var chosenCount: Int { chosen.count }

    var selectedSize: Int64 { chosen.reduce(0) { $0 + ($1.measurement?.size ?? 0) } }
    /// The measured size of everything that could be cleaned (Info rows excluded).
    var foundSize: Int64 {
        (report?.candidates ?? []).filter { $0.tier != .info }.reduce(0) { $0 + ($1.measurement?.size ?? 0) }
    }
    var needsAdmin: Bool { chosen.contains { $0.requiresAdmin } }
    /// Whether the ticked items include Trash ones (always deleted permanently).
    var selectedIncludesTrash: Bool { chosen.contains { $0.category == .trash } }
    /// The mode the last (or current) clean ran with, read from Settings when it started.
    private(set) var lastMode: DeleteMode = .permanent

    static func isSelectable(_ c: CleanCandidate) -> Bool { c.tier != .info && c.measurement != nil }

    // MARK: Check

    /// Runs `check()` if Settings' "Check for cleanable items at launch" is on (default on).
    func checkAtLaunchIfEnabled() {
        if defaults.object(forKey: Self.checkAtLaunchKey) as? Bool ?? true { check() }
    }

    /// Starts a check off the main actor at utility QoS, cancelling a running
    /// one first. Not while confirming or cleaning; behind a summary it runs
    /// without changing the phase.
    func check() {
        switch phase {
        case .confirming, .cleaning: return
        case .summary: break
        case .idle, .checking, .ready, .nothingFound: phase = .checking
        }
        checkTask?.cancel()
        generation += 1
        let mine = generation
        let engine = configured(makeEngine())
        let home = engine.home
        let pause: @Sendable (CleanRule) async -> Void = { [weak self] rule in
            guard let device = Self.targetDevice(pattern: rule.pattern, home: home) else { return }
            while !Task.isCancelled, await self?.isScanning(device) == true {
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
        let task = Task.detached(priority: .utility) { await engine.run(beforeRule: pause) }
        checkTask = task
        isChecking = true
        Task { [weak self] in
            let result = await task.value
            guard let self, mine == self.generation, !task.isCancelled else { return }
            self.checkTask = nil
            self.isChecking = false
            self.publish(result)
        }
    }

    /// Cancels a running check (window closed, app quitting); nothing is published.
    func cancelCheck() {
        guard let checkTask else { return }
        checkTask.cancel()
        self.checkTask = nil
        isChecking = false
        generation += 1
        if phase == .checking { phase = resting }
    }

    /// Adds `path` to the never-clean list, drops its row (and tick) at once, and checks again.
    func neverClean(_ path: String) {
        var list = defaults.stringArray(forKey: Self.neverCleanKey) ?? []
        if !list.contains(path) {
            list.append(path)
            defaults.set(list, forKey: Self.neverCleanKey)
        }
        selected.remove(path)
        report?.candidates.removeAll { $0.path == path }
        check()
    }

    /// Takes a check's result. Ticks carry over for paths already listed;
    /// new paths get the default (Safe with a known size).
    func publish(_ result: CleanReport) {
        let old = Set(report?.candidates.map(\.path) ?? [])
        selected = Set(result.candidates.filter { c in
            Self.isSelectable(c) && (old.contains(c.path) ? selected.contains(c.path) : c.tier == .safe)
        }.map(\.path))
        report = result
        if case .summary = phase { return }
        phase = resting
    }

    /// The phase when nothing runs: from the last report.
    private var resting: Phase {
        guard let report else { return .idle }
        return report.candidates.isEmpty ? .nothingFound : .ready
    }

    private func isScanning(_ device: Int32) -> Bool { scanning(device) }

    /// The engine with Settings applied: the never-clean list, disabled categories, extra project roots.
    private func configured(_ base: CleanEngine) -> CleanEngine {
        var env = base.environment
        env.neverClean = defaults.stringArray(forKey: Self.neverCleanKey) ?? []
        let disabled = Set((defaults.stringArray(forKey: Self.disabledCategoriesKey) ?? [])
            .compactMap(CleanRule.Category.init(rawValue:)))
        return CleanEngine(rules: base.rules, home: base.home, environment: env, probes: base.probes,
                           disabled: disabled, projectRoots: defaults.stringArray(forKey: Self.projectRootsKey) ?? [],
                           budget: base.budget)
    }

    /// The device of the longest existing literal prefix of `pattern` (`~` is
    /// `home`; an empty pattern, as for project artifacts, is `home`).
    nonisolated static func targetDevice(pattern: String, home: String) -> Int32? {
        var path = pattern.isEmpty ? home : pattern
        if path == "~" || path.hasPrefix("~/") { path = home + path.dropFirst() }
        if let wild = path.firstIndex(where: { "*?[{".contains($0) }) {
            path = String(path[..<wild])
        }
        while true {
            var st = stat()
            if stat(path, &st) == 0 { return st.st_dev }
            if path == "/" || path.isEmpty { return nil }
            path = (path as NSString).deletingLastPathComponent
        }
    }

    // MARK: Measure

    /// One administrator prompt (spec §5.3a) that fills in the measurement of
    /// size-unknown rows needing administrator rights. Rows root couldn't
    /// measure, and every row after a cancelled prompt, stay size unknown.
    func measureWithAdmin() async {
        guard phase == .ready, !measuring, let report else { return }
        let paths = report.candidates.filter { $0.requiresAdmin && $0.measurement == nil }.map(\.path)
        guard !paths.isEmpty else { return }
        generation += 1
        let mine = generation
        measuring = true
        defer { measuring = false }
        let lines: [String: AdminMeasure.Line]
        do {
            let (file, sha256) = try AdminMeasure.writePathsFile(paths)
            defer { AdminMeasure.removePathsFile(file) }
            var env = ProtectionEnvironment.current()
            env.neverClean = defaults.stringArray(forKey: Self.neverCleanKey) ?? []
            lines = AdminMeasure.decode(try await admin.run(AdminMeasure.arguments(pathsFile: file.path,
                                                                                   sha256: sha256, environment: env),
                                                     prompt: Self.measurePrompt(count: paths.count)))
        } catch {
            return
        }
        // A check started meanwhile owns the report now.
        guard mine == generation, var current = self.report else { return }
        current.candidates = current.candidates.map { c in
            guard c.requiresAdmin, c.measurement == nil, let line = lines[c.path], line.error == nil,
                  let m = line.measurement else { return c }
            return CleanCandidate(path: c.path, ruleID: c.ruleID, category: c.category, tier: c.tier,
                                  displayName: c.displayName, reason: c.reason, measurement: m,
                                  requiresAdmin: c.requiresAdmin, owner: c.owner, group: c.group)
        }
        self.report = current
    }

    // MARK: Clean

    /// Shows the confirmation alert (the view's), if anything is ticked.
    func requestClean() {
        guard phase == .ready, !measuring, !chosen.isEmpty else { return }
        phase = .confirming
    }

    /// The alert's Cancel.
    func cancelClean() {
        if phase == .confirming { phase = resting }
    }

    /// While cleaning: stops after the current item. Not while the administrator prompt is up.
    func stop() {
        if case .cleaning = phase, !awaitingAdmin { stopRequested = true }
    }

    /// Deletes the ticked items (after the view's confirmation alert), then
    /// shows the summary, marks deleted items removed in open scan results
    /// and checks again in the background.
    func clean() async {
        guard phase == .ready || phase == .confirming, !measuring else { return }
        let targets = chosen
        guard !targets.isEmpty else {
            phase = resting
            return
        }
        cancelCheck()
        let mode: DeleteMode = defaults.bool(forKey: DeleteController.trashKey) ? .trash : .permanent
        lastMode = mode
        var requests: [String: DeleteRequest] = [:]
        var owners: [String: String] = [:]
        let items = targets.compactMap { c -> DeleteBatch.Item? in
            guard let request = Self.request(for: c) else { return nil }
            requests[c.path] = request
            owners[c.path] = c.owner
            // Emptying the Trash means deleting permanently. System items go
            // straight to the administrator batch (R27).
            return DeleteBatch.Item(request: request, force: false, mode: c.category == .trash ? .permanent : nil,
                                    adminOnly: c.requiresAdmin)
        }
        let batch = DeleteBatch(mode: mode, context: .smartClean, makeDeleter: makeDeleter, admin: admin,
                                neverClean: defaults.stringArray(forKey: Self.neverCleanKey) ?? [])
        self.batch = batch
        stopRequested = false
        phase = .cleaning(done: 0, total: items.count)
        let probes = probes
        let result = await batch.run(items, shouldStop: { [unowned self] in stopRequested },
                                     progress: { [unowned self] done, total in phase = .cleaning(done: done, total: total) },
                                     beforeEach: { item in
            guard let owner = owners[item.request.path], probes.isRunning(bundleID: owner) != false else { return nil }
            return "\(Self.appName(owner)) is open."
        })
        self.batch = nil
        registry?.markRemoved((result.deleted + result.alreadyGone).compactMap { requests[$0] })
        // Free-space figures (start screen, open results) refresh.
        if !result.deleted.isEmpty { notifications.post(name: .macleanDidDelete, object: nil) }
        phase = .summary(result)
        check()
    }

    func dismissSummary() {
        guard case .summary = phase else { return }
        phase = checkTask != nil ? .checking : resting
    }

    /// The delete request for a measured candidate, with the check's identity and size.
    static func request(for c: CleanCandidate) -> DeleteRequest? {
        guard let m = c.measurement else { return nil }
        let cache = c.tier == .safe && cacheCategories.contains(c.category)
        return DeleteRequest(path: c.path, inode: m.inode, device: m.device, size: m.size, fileCount: m.fileCount,
                             isDirectory: m.isDirectory, tolerance: cache ? .cache : .strict)
    }

    /// The last component of a bundle id ("com.google.Chrome" → "Chrome").
    nonisolated static func appName(_ bundleID: String) -> String {
        bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}
