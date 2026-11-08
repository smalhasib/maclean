import Foundation
import Testing
@testable import MacleanCore

private func days(_ n: Double) -> Date { Date().addingTimeInterval(n * 86400) }

private func rule(_ id: String, _ pattern: String, unit: CleanRule.Unit = .folder,
                  category: CleanRule.Category = .systemServices,
                  tiers: [(days: Int, tier: CleanRule.Tier)] = [(0, .review)],
                  owner: CleanRule.Owner = .none, special: CleanRule.Special) -> CleanRule {
    CleanRule(id: id, category: category, pattern: pattern, unit: unit, ageTiers: tiers, owner: owner,
              special: special, reason: "Base reason")
}

/// The catalog's user-level leftovers, window state and generic sweeps, in catalog order.
private let leftoverAndSweeps = CleanCatalog.rules.filter {
    $0.id.hasPrefix("leftover.") || $0.id == "windowState" || $0.id.hasPrefix("cache.") || $0.id.hasPrefix("logs.")
}

private func writePlist(_ object: Any, to path: String) {
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
    let data = try! PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    try! data.write(to: URL(fileURLWithPath: path))
}

private struct Fixture {
    let t = TempDir()
    var home: String { t.url("home") }
    init() { t.dir("home") }

    func run(_ rules: [CleanRule], probes: FakeProbes = FakeProbes()) async -> CleanReport {
        let env = ProtectionEnvironment(home: home, appBundle: "/Applications/Maclean.app", mountPoints: ["/"],
                                        timeMachineMounts: [], neverClean: [])
        return await CleanEngine(rules: rules, home: home, environment: env, probes: probes).run()
    }
}

@Suite struct CleanSpecialsTests {
    // MARK: Leftovers of removed apps

    @Test func leftoverOfUninstalledAppOffered() async {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        f.t.file("home/Library/Caches/com.gone.app/x", bytes: 10)
        let r = await f.run(leftoverAndSweeps, probes: FakeProbes(now: days(40), installed: ["com.a.b"]))
        let c = r.candidates.first { $0.path == f.t.url("home/Library/Caches/com.gone.app") }
        #expect(c?.ruleID == "leftover.caches")
        #expect(c?.category == .removedApps)
        #expect(c?.tier == .review)
        #expect(c?.displayName == "App")
    }

    @Test func leftoverOfInstalledAppNotLeftover() async {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        f.t.file("home/Library/Caches/com.a.b/x", bytes: 10)
        f.t.file("home/Library/Logs/com.a.b/x", bytes: 10)
        f.t.file("home/Library/Caches/com.a.b.helper/x", bytes: 10)
        f.t.file("home/Library/Caches/com.apple.akd/x", bytes: 10)
        let r = await f.run(leftoverAndSweeps, probes: FakeProbes(now: days(40), installed: ["com.a.b"]))
        let byPath = Dictionary(uniqueKeysWithValues: r.candidates.map { ($0.path, $0.ruleID) })
        #expect(byPath[f.t.url("home/Library/Caches/com.a.b")] == "cache.app")
        #expect(byPath[f.t.url("home/Library/Logs/com.a.b")] == "logs.user")
        // A helper id under an installed id counts as installed.
        #expect(byPath[f.t.url("home/Library/Caches/com.a.b.helper")] == "cache.app")
        // Apple daemons aren't uninstalled apps.
        #expect(byPath[f.t.url("home/Library/Caches/com.apple.akd")] == "cache.app")
    }

    @Test func savedStateFallsThroughToWindowState() async {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        let sas = "home/Library/Saved Application State"
        f.t.file("\(sas)/Odd App.savedState/x", bytes: 10)
        f.t.file("\(sas)/com.a.b.savedState/x", bytes: 10)
        f.t.file("\(sas)/com.gone.app.savedState/x", bytes: 10)
        let r = await f.run(leftoverAndSweeps, probes: FakeProbes(now: days(40), installed: ["com.a.b"]))
        let byPath = Dictionary(uniqueKeysWithValues: r.candidates.map { ($0.path, $0.ruleID) })
        #expect(byPath[f.t.url("\(sas)/Odd App.savedState")] == "windowState")
        #expect(byPath[f.t.url("\(sas)/com.a.b.savedState")] == "windowState")
        #expect(byPath[f.t.url("\(sas)/com.gone.app.savedState")] == "leftover.savedState")
    }

    @Test func leftoverWithNeverDeleteWordSkipped() async {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        f.t.file("home/Library/Caches/com.x.bitwarden-helper/x", bytes: 10)
        let path = f.t.url("home/Library/Caches/com.x.bitwarden-helper")
        let r = await f.run(leftoverAndSweeps, probes: FakeProbes(now: days(40), installed: ["com.a.b"]))
        #expect(!r.candidates.contains { $0.path == path })
        #expect(r.skipped.contains(SkippedItem(path: path, reason: .protected(.protectedApp))))
    }

    @Test func installedCheckFailureSkipsCategory() async {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        f.t.file("home/Library/Caches/com.gone.app/x", bytes: 10)
        f.t.file("home/Library/Logs/com.gone.app/x", bytes: 10)
        f.t.file("home/Library/Containers/com.gone.app/x", bytes: 10)
        f.t.file("home/Library/Caches/Plain/x", bytes: 10)
        let r = await f.run(leftoverAndSweeps, probes: FakeProbes(now: days(40), installed: nil))
        #expect(!r.candidates.contains { $0.category == .removedApps })
        for p in ["Caches", "Logs", "Containers"].map({ f.t.url("home/Library/\($0)/com.gone.app") }) {
            #expect(r.skipped.contains(SkippedItem(path: p, reason: .installedCheckFailed)))
            #expect(!r.candidates.contains { $0.path == p })     // never offered as a Safe cache either
        }
        #expect(r.candidates.first { $0.path == f.t.url("home/Library/Caches/Plain") }?.ruleID == "cache.other")
    }

    @Test func youngLeftoverIsRecent() async {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        f.t.file("home/Library/Caches/com.gone.app/x", bytes: 10)
        let r = await f.run(leftoverAndSweeps, probes: FakeProbes(now: days(10)))
        #expect(r.candidates.isEmpty)
        #expect(r.skipped == [SkippedItem(path: f.t.url("home/Library/Caches/com.gone.app"), reason: .recent)])
    }

    // MARK: launchd orphans

    @Test func launchdOrphanNeedsMissingProgram() async {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        writePlist(["Label": "a", "Program": "/nonexistent"], to: f.t.url("home/LD/a.plist"))
        writePlist(["Label": "b", "Program": "/bin/ls"], to: f.t.url("home/LD/b.plist"))
        writePlist(["Label": "c", "ProgramArguments": ["/nonexistent2/tool", "-x"]], to: f.t.url("home/LD/c.plist"))
        writePlist(["Label": "d", "ProgramArguments": ["relative", "-x"]], to: f.t.url("home/LD/d.plist"))
        let r = await f.run([rule("ld", "~/LD/*.plist", special: .launchdOrphan)])
        #expect(r.candidates.map(\.path) == [f.t.url("home/LD/a.plist"), f.t.url("home/LD/c.plist")])
        #expect(r.candidates[0].reason.contains("/nonexistent"))
        #expect(r.candidates[1].reason.contains("/nonexistent2/tool"))
    }

    @Test func helperOfUninstalledAppIsOrphan() async {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        func helper(_ name: String, client: String) {
            let plist = try! PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": name,
                "SMAuthorizedClients": ["identifier \"\(client)\" and anchor apple generic"],
            ], format: .xml, options: 0)
            f.t.dir("home/PHT")
            var bytes = Data([0xCF, 0xFA, 0xED, 0xFE] + [UInt8](repeating: 0, count: 64))
            bytes += plist + Data(repeating: 0, count: 32)
            try! bytes.write(to: URL(fileURLWithPath: f.t.url("home/PHT/\(name)")))
        }
        helper("com.gone.helper", client: "com.gone.app")
        helper("com.a.helper", client: "com.a.b")
        f.t.file("home/PHT/no-plist", bytes: 100)
        let r = await f.run([rule("pht", "~/PHT", unit: .eachChild, special: .launchdOrphan)],
                            probes: FakeProbes(installed: ["com.a.b"]))
        #expect(r.candidates.map(\.path) == [f.t.url("home/PHT/com.gone.helper")])
        #expect(r.candidates.first?.reason.contains("com.gone.app") == true)
        #expect(r.skipped == [SkippedItem(path: f.t.url("home/PHT/no-plist"), reason: .ownerUnknown)])

        let failed = await f.run([rule("pht", "~/PHT", unit: .eachChild, special: .launchdOrphan)],
                                 probes: FakeProbes(installed: nil))
        #expect(failed.candidates.isEmpty)
        #expect(failed.skipped.contains(SkippedItem(path: f.t.url("home/PHT/com.gone.helper"),
                                                    reason: .installedCheckFailed)))
    }

    // MARK: Installers

    @Test func installerSameOSVersionSkipped() async {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let current = "\(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : "")
        writePlist(["CFBundleShortVersionString": current],
                   to: f.t.url("home/Apps/Install macOS Same.app/Contents/Info.plist"))
        writePlist(["CFBundleShortVersionString": "10.9"],
                   to: f.t.url("home/Apps/Install macOS Old.app/Contents/Info.plist"))
        let installer = rule("inst", "~/Apps/Install macOS*.app", category: .oldInstallers, tiers: [(14, .review)],
                             special: .macOSInstaller)
        let r = await f.run([installer], probes: FakeProbes(now: days(20)))
        #expect(r.candidates.map(\.path) == [f.t.url("home/Apps/Install macOS Old.app")])
        #expect(r.skipped == [SkippedItem(path: f.t.url("home/Apps/Install macOS Same.app"), reason: .sameOSInstaller)])

        let young = await f.run([installer], probes: FakeProbes(now: days(5)))
        #expect(young.candidates.isEmpty)
        #expect(young.skipped.map(\.reason) == [.recent, .recent])
    }

    @Test func downloadsInstallerAgeFromDateAdded() async throws {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        f.t.file("home/Downloads/old.dmg", bytes: 10)
        f.t.file("home/Downloads/new.pkg", bytes: 10)
        let added = try PropertyListSerialization.data(fromPropertyList: days(-40), format: .binary, options: 0)
        let rc = added.withUnsafeBytes {
            setxattr(f.t.url("home/Downloads/old.dmg"), "com.apple.metadata:kMDItemDateAdded",
                     $0.baseAddress, added.count, 0, 0)
        }
        #expect(rc == 0)
        let downloads = rule("dl", "~/Downloads/*.{dmg,pkg}", category: .oldInstallers, tiers: [(30, .review)],
                             special: .downloadsInstaller)
        let r = await f.run([downloads])
        #expect(r.candidates.map(\.path) == [f.t.url("home/Downloads/old.dmg")])
        #expect(r.candidates.first?.reason == "Installer image downloaded 40 days ago")
        // No xattr: the birth time (now) is used.
        #expect(r.skipped == [SkippedItem(path: f.t.url("home/Downloads/new.pkg"), reason: .recent)])
    }

    // MARK: DerivedData, Darwin caches

    @Test func derivedDataShowsProjectName() async {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        writePlist(["WorkspacePath": "/x/MyApp.xcodeproj"], to: f.t.url("home/DD/MyApp-abcdef/info.plist"))
        f.t.file("home/DD/NoInfo-123/x", bytes: 10)
        let dd = rule("dd", "~/DD", unit: .eachChild, category: .developer, special: .derivedData)
        let r = await f.run([dd])
        let names = Dictionary(uniqueKeysWithValues: r.candidates.map { ($0.path, $0.displayName) })
        #expect(names[f.t.url("home/DD/MyApp-abcdef")] == "MyApp")
        #expect(names[f.t.url("home/DD/NoInfo-123")] == "NoInfo-123")
    }

    @Test func darwinCacheSkippedWhenSecurityToolPresent() async {
        let f = Fixture()
        defer { withExtendedLifetime(f) {} }
        f.t.file("home/C/com.apple.metal/x", bytes: 10)
        let metal = rule("metal", "~/C/com.apple.metal", category: .systemCaches, tiers: [(1, .safe)],
                         special: .skipIfSecurityTool)
        let watched = await f.run([metal], probes: FakeProbes(now: days(2), securityTool: true))
        #expect(watched.candidates.isEmpty)
        #expect(watched.skipped == [SkippedItem(path: f.t.url("home/C/com.apple.metal"), reason: .protected(.protectedApp))])
        let clear = await f.run([metal], probes: FakeProbes(now: days(2)))
        #expect(clear.candidates.map(\.path) == [f.t.url("home/C/com.apple.metal")])
    }

    @Test func catalogDarwinRowsSkipIfSecurityTool() {
        let rows = CleanCatalog.rules.filter { $0.id.hasPrefix("sys.darwin.") }
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { if case .skipIfSecurityTool = $0.special { true } else { false } })
        #expect(CleanCatalog.securityToolFolders.contains("/opt/cisco"))
    }

    // MARK: Installed apps

    @Test func installedAppsReadsBundlesToDepthThree() {
        let t = TempDir()
        defer { withExtendedLifetime(t) {} }
        func app(_ rel: String, _ id: String) {
            writePlist(["CFBundleIdentifier": id], to: t.url("\(rel)/Contents/Info.plist"))
        }
        app("Apps/One.app", "com.one")
        app("Apps/Group/Two.app", "com.two")
        app("Apps/A/B/Three.app", "com.three")
        app("Apps/A/B/C/Four.app", "com.four")
        app("Apps/One.app/Contents/Helpers/Inner.app", "com.inner")
        app("Cask/tool/1.0/Five.app", "com.five")
        let ids = InstalledApps.bundleIDs(searchRoots: [t.url("Apps"), t.url("Cask"), t.url("missing")],
                                          extra: ["com.extra"])
        #expect(ids == ["com.one", "com.two", "com.three", "com.five", "com.extra"])
        #expect(InstalledApps.bundleIDs(searchRoots: [t.url("missing"), t.url("Apps")], extra: []) == nil)
    }
}
