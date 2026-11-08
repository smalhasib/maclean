import Foundation
import Testing
@testable import MacleanCore

/// Probes with fixed answers. Age is simulated by moving `now` forward (R7):
/// tests can't backdate ctime, which `Measurement.newest` includes.
struct FakeProbes: CleanProbes {
    var now: Date = Date()
    var running: Set<String> = []
    var unknownOwners: Set<String> = []
    var open: Set<String> = []
    var processes: Set<String> = []
    var appSupport: [String: String] = [:]
    /// nil = the installed-apps check failed.
    var installed: Set<String>? = []
    var securityTool = false

    func isRunning(bundleID: String) -> Bool? {
        unknownOwners.contains(bundleID) ? nil : running.contains(bundleID)
    }
    func isOpen(path: String) -> Bool? { open.contains(path) }
    func isProcessRunning(name: String) -> Bool? { processes.contains(name) }
    func bundleID(appSupportFolder: String) -> String? { appSupport[appSupportFolder] }
    func installedBundleIDs() -> Set<String>? { installed }
    func projectArtifacts(roots: [String]) -> [ProjectArtifact] { [] }
    func workingDirectories() -> [String]? { [] }
    func securityToolInstalled() -> Bool { securityTool }
}

private func days(_ n: Double) -> Date { Date().addingTimeInterval(n * 86400) }

private func setMtime(_ path: String, daysAgo: Double) {
    let t = timeval(tv_sec: Int(Date().timeIntervalSince1970 - daysAgo * 86400), tv_usec: 0)
    var times = [t, t]
    precondition(utimes(path, &times) == 0)
}

private func rule(_ id: String, _ pattern: String, unit: CleanRule.Unit = .eachChild,
                  category: CleanRule.Category = .appCaches,
                  tiers: [(days: Int, tier: CleanRule.Tier)] = [(0, .safe)],
                  owner: CleanRule.Owner = .none, fileFilter: [String]? = nil, exclude: [String] = [],
                  requiresAdmin: Bool = false, requireNotOpen: Bool = false,
                  special: CleanRule.Special = .none) -> CleanRule {
    CleanRule(id: id, category: category, pattern: pattern, unit: unit, ageTiers: tiers, owner: owner,
              fileFilter: fileFilter, exclude: exclude, requiresAdmin: requiresAdmin,
              requireNotOpen: requireNotOpen, special: special, reason: "test")
}

/// A fake home inside a TempDir.
private struct Fixture {
    let t = TempDir()
    var home: String { t.url("home") }
    init() { t.dir("home") }

    func env(neverClean: [String] = []) -> ProtectionEnvironment {
        ProtectionEnvironment(home: home, appBundle: "/Applications/Maclean.app", mountPoints: ["/"],
                              timeMachineMounts: [], neverClean: neverClean)
    }

    func run(_ rules: [CleanRule], probes: FakeProbes = FakeProbes(), neverClean: [String] = [],
             disabled: Set<CleanRule.Category> = [], budget: Duration = .seconds(5)) async -> CleanReport {
        let engine = CleanEngine(rules: rules, home: home, environment: env(neverClean: neverClean),
                                 probes: probes, disabled: disabled, budget: budget)
        return await engine.run()
    }
}

@Suite struct CleanEngineTests {
    @Test func ageTiersPickSafeReviewOrRecent() async {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        f.t.file("home/Library/Caches/a/x", bytes: 100)
        f.t.file("home/Library/Logs/b/y", bytes: 100)
        let tiered = rule("tiered", "~/Library/Caches", tiers: [(14, .safe), (0, .review)])
        let weekly = rule("weekly", "~/Library/Logs", category: .logs, tiers: [(7, .safe)])

        let old = await f.run([tiered, weekly], probes: FakeProbes(now: days(20)))
        #expect(old.candidates.first { $0.ruleID == "tiered" }?.tier == .safe)
        #expect(old.candidates.first { $0.ruleID == "weekly" }?.tier == .safe)

        let fresh = await f.run([tiered, weekly], probes: FakeProbes(now: days(3)))
        #expect(fresh.candidates.first { $0.ruleID == "tiered" }?.tier == .review)

        let young = await f.run([weekly], probes: FakeProbes(now: days(2)))
        #expect(young.candidates.isEmpty)
        #expect(young.skipped == [SkippedItem(path: f.t.url("home/Library/Logs/b"), reason: .recent)])
    }

    @Test func firstMatchingRuleWins() async {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        f.t.file("home/Library/Caches/Yarn/v6/pkg", bytes: 10)
        f.t.file("home/Library/Caches/Other/z", bytes: 10)
        let yarn = rule("yarn", "~/Library/Caches/Yarn", unit: .folder, category: .developer,
                        tiers: [(0, .review)])
        let sweep = rule("sweep", "~/Library/Caches")
        let r = await f.run([yarn, sweep])
        let yarnPath = f.t.url("home/Library/Caches/Yarn")
        #expect(r.candidates.filter { $0.path == yarnPath }.map(\.ruleID) == ["yarn"])
        #expect(r.candidates.map(\.path).sorted() == [f.t.url("home/Library/Caches/Other"), yarnPath])
        #expect(r.candidates.first { $0.path == yarnPath }?.category == .developer)
    }

    @Test func runningOwnerSkipped() async {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        f.t.file("home/Library/Caches/com.example.app/x", bytes: 10)
        f.t.file("home/Library/Caches/com.example.idle/x", bytes: 10)
        let r = await f.run([rule("c", "~/Library/Caches", owner: .childNameIfBundleID)],
                            probes: FakeProbes(running: ["com.example.app"]))
        #expect(r.skipped == [SkippedItem(path: f.t.url("home/Library/Caches/com.example.app"),
                                          reason: .appRunning("com.example.app"))])
        #expect(r.candidates.map(\.path) == [f.t.url("home/Library/Caches/com.example.idle")])
        #expect(r.candidates.first?.owner == "com.example.idle")
    }

    @Test func unknownOwnerSkipped() async {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        f.t.file("home/Library/Caches/com.example.app/x", bytes: 10)
        let r = await f.run([rule("c", "~/Library/Caches", owner: .childNameIfBundleID)],
                            probes: FakeProbes(unknownOwners: ["com.example.app"]))
        #expect(r.candidates.isEmpty)
        #expect(r.skipped.map(\.reason) == [.ownerUnknown])
    }

    @Test func containerOpenFileSkipped() async {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        f.t.file("home/Library/Containers/com.example.app/Data/Library/Caches/db/x", bytes: 10)
        let path = f.t.url("home/Library/Containers/com.example.app/Data/Library/Caches/db")
        let r = await f.run([rule("k", "~/Library/Containers/*/Data/Library/Caches", owner: .containerBundleID)],
                            probes: FakeProbes(open: [path]))
        #expect(r.candidates.isEmpty)
        #expect(r.skipped == [SkippedItem(path: path, reason: .appRunning("com.example.app"))])
    }

    @Test func protectedChildSkipped() async {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        f.t.file("home/Library/Caches/com.example.keep/x", bytes: 10)
        f.t.file("home/Library/Caches/com.apple.private.thing/x", bytes: 10)
        let r = await f.run([rule("c", "~/Library/Caches", owner: .childNameIfBundleID)],
                            neverClean: ["~/Library/Caches/com.example.keep"])
        #expect(r.candidates.isEmpty)
        #expect(r.skipped.count == 2)
        #expect(r.skipped.contains { $0.reason == .macOSSystemCache })
        #expect(r.skipped.first { $0.reason == .neverClean }?.path == f.t.url("home/Library/Caches/com.example.keep"))
    }

    @Test func overBudgetIsSizeUnknown() async {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        f.t.file("home/Library/Caches/big/x", bytes: 10)
        let r = await f.run([rule("c", "~/Library/Caches", tiers: [(14, .safe), (0, .review)])], budget: .zero)
        #expect(r.candidates.count == 1)
        #expect(r.candidates.first?.measurement == nil)
        #expect(r.candidates.first?.tier == .review)      // lowest tier: never auto-ticked
    }

    @Test func keepNewestKeepsTwo() async {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        for (i, age) in [40.0, 30, 20, 10].enumerated() {
            f.t.dir("home/DS/1\(i).0")
            setMtime(f.t.url("home/DS/1\(i).0"), daysAgo: age)
        }
        let r = await f.run([rule("ds", "~/DS", category: .developer, tiers: [(0, .review)], special: .keepNewest(2))])
        #expect(r.candidates.map(\.path).sorted() == [f.t.url("home/DS/10.0"), f.t.url("home/DS/11.0")])
    }

    @Test func excludeAndFileFilterApply() async {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        f.t.file("home/dl/a.tar.gz", bytes: 10)
        f.t.file("home/dl/b.incomplete", bytes: 10)
        f.t.file("home/logs/x.log", bytes: 10)
        f.t.file("home/logs/y.txt", bytes: 10)
        f.t.file("home/logs/z.log/inner", bytes: 10)
        let r = await f.run([
            rule("dl", "~/dl", exclude: ["*.incomplete"]),
            rule("logs", "~/logs", category: .logs, fileFilter: ["*.log"]),
        ])
        #expect(r.candidates.map(\.path).sorted() == [f.t.url("home/dl/a.tar.gz"), f.t.url("home/logs/x.log")])
        #expect(r.skipped.isEmpty)
    }

    @Test func disabledCategoryOffersNothing() async {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        f.t.file("home/Library/Caches/a/x", bytes: 10)
        f.t.file("home/Library/Logs/b/y", bytes: 10)
        let r = await f.run([rule("c", "~/Library/Caches"), rule("l", "~/Library/Logs", category: .logs)],
                            disabled: [.appCaches])
        #expect(r.candidates.map(\.ruleID) == ["l"])
        #expect(r.skipped == [SkippedItem(path: f.t.url("home/Library/Caches/a"), reason: .categoryOff)])
    }

    @Test func symlinkedRootExpandsNothingOutside() async {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        f.t.file("elsewhere/com.x.y/data", bytes: 10)
        f.t.file("elsewhere/Cache/data", bytes: 10)
        f.t.dir("home/Library")
        f.t.symlink("home/Library/Caches", to: f.t.url("elsewhere"))
        f.t.file("home/Apps/real/Cache/x", bytes: 10)
        f.t.symlink("home/Apps/linked", to: f.t.url("elsewhere"))
        #expect(CleanEngine.expand("~/Library/Caches/*", home: f.home).isEmpty)
        #expect(CleanEngine.expand("~/Apps/*/Cache", home: f.home) == [f.t.url("home/Apps/real/Cache")])
        let r = await f.run([rule("c", "~/Library/Caches"), rule("a", "~/Apps/*/{Cache,data}", unit: .folder)])
        #expect(r.candidates.map(\.path) == [f.t.url("home/Apps/real/Cache")])
        #expect(r.candidates.allSatisfy { PathUtil.isInside($0.path, orEqualTo: f.home) })
    }

    @Test func expandResolvesTildeAgainstEngineHomeAndBraces() {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        f.t.dir("home/.gradle/daemon")
        f.t.dir("home/.gradle/workers")
        f.t.dir("home/.gradle/caches")
        #expect(CleanEngine.expand("~/.gradle/{daemon,workers,notifications}", home: f.home).sorted()
                == [f.t.url("home/.gradle/daemon"), f.t.url("home/.gradle/workers")])
    }

    @Test func parentOfEarlierRuleRootNotOffered() async {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        f.t.file("home/Library/Logs/Sim/a/x", bytes: 10)
        let sim = rule("sim", "~/Library/Logs/Sim", category: .developer)
        let logs = rule("logs", "~/Library/Logs", category: .logs)
        let r = await f.run([sim, logs])
        #expect(r.candidates.map(\.path) == [f.t.url("home/Library/Logs/Sim/a")])
    }

    @Test func leftoverOfInstalledAppFallsThrough() async {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        f.t.file("home/Library/Caches/com.a.b/x", bytes: 10)
        let leftovers = rule("left", "~/Library/Caches", category: .removedApps, tiers: [(30, .review)],
                             owner: .childNameIfBundleID, special: .removedAppLeftover)
        let r = await f.run([leftovers, rule("c", "~/Library/Caches", owner: .childNameIfBundleID)],
                            probes: FakeProbes(installed: ["com.a.b"]))
        #expect(r.candidates.map(\.ruleID) == ["c"])
    }

    @Test func sizeUnknownNeverSafe() async {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        f.t.file("home/Library/Caches/big/x", bytes: 10)
        f.t.file("home/Info/data/x", bytes: 10)
        let r = await f.run([rule("c", "~/Library/Caches", tiers: [(0, .safe)]),
                             rule("i", "~/Info", unit: .folder, category: .largeData, tiers: [(0, .info)])],
                            budget: .zero)
        let c = r.candidates.first { $0.ruleID == "c" }
        #expect(c != nil && c?.measurement == nil)
        #expect(c.map { $0.tier < .safe } == true)
        #expect(c?.tier == .review)
        #expect(r.candidates.first { $0.ruleID == "i" }?.tier == .info)
    }

    @Test func openFileWithoutOwnerIsInUse() async {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        f.t.file("home/logs/a.log", bytes: 10)
        let path = f.t.url("home/logs/a.log")
        let r = await f.run([rule("l", "~/logs", category: .logs, requireNotOpen: true)],
                            probes: FakeProbes(open: [path]))
        #expect(r.candidates.isEmpty)
        #expect(r.skipped == [SkippedItem(path: path, reason: .inUse)])
    }

    @Test func trashOffersDotNamedChildren() async {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        f.t.file("home/.Trash/.hidden", bytes: 10)
        f.t.file("home/.Trash/visible", bytes: 10)
        f.t.file("home/Library/Caches/.dot/x", bytes: 10)
        let r = await f.run([rule("t", "~/.Trash", category: .trash, tiers: [(0, .review)]),
                             rule("c", "~/Library/Caches")])
        #expect(r.candidates.map(\.path).sorted() == [f.t.url("home/.Trash/.hidden"), f.t.url("home/.Trash/visible")])
        let trash = rule("t", "~/.Trash", category: .trash, tiers: [(0, .review)])
        #expect(CleanEngine.rule(matching: f.t.url("home/.Trash/.hidden"), in: [trash], home: f.home)?.id == "t")
    }

    @Test func windowStateClaimsNonBundleNames() async {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        f.t.file("home/SAS/Odd App.savedState/x", bytes: 10)
        f.t.file("home/SAS/com.example.app.savedState/x", bytes: 10)
        let ws = rule("ws", "~/SAS/*.savedState", unit: .folder, category: .windowState, tiers: [(0, .review)],
                      owner: .childNameIfBundleID)
        let r = await f.run([ws], probes: FakeProbes(running: ["com.example.app"]))
        #expect(r.candidates.map(\.path) == [f.t.url("home/SAS/Odd App.savedState")])
        #expect(r.candidates.first?.owner == nil)
        #expect(r.skipped == [SkippedItem(path: f.t.url("home/SAS/com.example.app.savedState"),
                                          reason: .appRunning("com.example.app"))])
    }

    @Test func unreadableUserItemIsNoAccess() async {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        f.t.file("home/Library/Caches/locked/x", bytes: 10)
        f.t.chmod("home/Library/Caches/locked", 0)
        let r = await f.run([rule("c", "~/Library/Caches")])
        #expect(r.candidates.isEmpty)
        #expect(r.skipped == [SkippedItem(path: f.t.url("home/Library/Caches/locked"), reason: .noAccess)])
    }

    @Test func unreadableAdminItemIsSizeUnknown() async {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        f.t.file("home/Library/Caches/locked/x", bytes: 10)
        f.t.chmod("home/Library/Caches/locked", 0)
        let r = await f.run([rule("c", "~/Library/Caches", tiers: [(7, .safe)], requiresAdmin: true)],
                            probes: FakeProbes(now: days(10)))
        #expect(r.skipped.isEmpty)
        #expect(r.candidates.count == 1)
        #expect(r.candidates.first?.measurement == nil)
        #expect(r.candidates.first?.tier == .review)
        #expect(r.candidates.first?.requiresAdmin == true)
    }

    @Test func staticMatchPassesOverLeftoverRules() {
        let leftovers = rule("left", "~/Library/Caches", category: .removedApps, tiers: [(30, .review)],
                             owner: .childNameIfBundleID, special: .removedAppLeftover)
        let generic = rule("c", "~/Library/Caches", owner: .childNameIfBundleID)
        #expect(CleanEngine.rule(matching: "/h/Library/Caches/com.gone.app", in: [leftovers, generic], home: "/h")?.id == "c")
        #expect(CleanEngine.rule(matching: "/h/Library/Caches/com.gone.app", in: [leftovers], home: "/h") == nil)
    }
}
