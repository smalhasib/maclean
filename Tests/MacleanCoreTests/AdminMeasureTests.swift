import Foundation
import Testing
@testable import MacleanCore

private let env = ProtectionEnvironment(home: "/Users/me", appBundle: "/Applications/Maclean.app",
                                        mountPoints: ["/", "/Volumes/Ext"], timeMachineMounts: ["/Volumes/TM"],
                                        neverClean: ["~/Keep"])

private func fakeRule(_ dir: String, admin: Bool = true) -> CleanRule {
    CleanRule(id: "test.admin", category: .systemLogs, pattern: dir, unit: .eachChild, ageTiers: [(7, .safe)],
              requiresAdmin: admin, reason: "test")
}

@Test func measureArgumentsRoundTrip() throws {
    let paths = ["/Library/Logs/a b", "/private/var/log/new\nline.log", "/Library/Caches/--delete", "/x/$(rm -rf ~) é"]
    let (file, hash) = try AdminMeasure.writePathsFile(paths)
    defer { AdminMeasure.removePathsFile(file) }
    let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attrs[.posixPermissions] as? Int) == 0o600)

    let args = AdminMeasure.arguments(pathsFile: file.path, sha256: hash, environment: env)
    #expect(args == ["smart-measure", "--env", args[2], "--paths-file", file.path, "--paths-sha256", hash])
    let parsed = try AdminMeasure.parse(args)
    #expect(parsed.paths == paths)
    #expect(parsed.environment == env)

    #expect(throws: (any Error).self) { try AdminMeasure.parse(Array(args.dropLast())) }
    #expect(throws: (any Error).self) { try AdminMeasure.parse(args + ["extra"]) }
    var wrongMode = args
    wrongMode[0] = "--delete"
    #expect(throws: (any Error).self) { try AdminMeasure.parse(wrongMode) }
    var garbled = args
    garbled[2] = "not json"
    #expect(throws: (any Error).self) { try AdminMeasure.parse(garbled) }

    AdminMeasure.removePathsFile(file)
    #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
}

@Test func measureRefusesTamperedPathsFile() throws {
    let (file, hash) = try AdminMeasure.writePathsFile(["/Library/Logs/a"])
    defer { AdminMeasure.removePathsFile(file) }
    let dir = file.deletingLastPathComponent()
    let good = AdminMeasure.arguments(pathsFile: file.path, sha256: hash, environment: env)
    #expect(try AdminMeasure.parse(good).paths == ["/Library/Logs/a"])

    // Rewritten after the hash was taken.
    try Data(#"["/Library/Logs/b"]"#.utf8).write(to: file)
    #expect(throws: (any Error).self) { try AdminMeasure.parse(good) }

    // A symlink to a file with matching contents is not followed.
    let (fresh, freshHash) = try AdminMeasure.writePathsFile(["/Library/Logs/a"])
    defer { AdminMeasure.removePathsFile(fresh) }
    let link = dir.appending(path: "link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fresh)
    var other = AdminMeasure.arguments(pathsFile: link.path, sha256: freshHash, environment: env)
    #expect(throws: (any Error).self) { try AdminMeasure.parse(other) }

    // A FIFO is not a regular file (and must not block the helper).
    let fifo = dir.appending(path: "fifo")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    other[4] = fifo.path
    #expect(throws: (any Error).self) { try AdminMeasure.parse(other) }
}

@Test func measureLinesRoundTrip() {
    let m = Measurement(size: 4096, fileCount: 3, newest: Date(timeIntervalSince1970: 1_700_000_000), inode: 42,
                        device: 7, isDirectory: true, restricted: false)
    let lines = [
        AdminMeasure.Line(path: "/Library/Logs/a\nb", measurement: m, error: nil),
        AdminMeasure.Line(path: "/Users/me/x", measurement: nil, error: AdminMeasure.notATarget),
    ]
    var text = lines.map(AdminMeasure.encode)
    #expect(text.allSatisfy { !$0.contains("\n") && !$0.contains("\r") })
    text.insert("garbage {", at: 1)
    let expected = Dictionary(uniqueKeysWithValues: lines.map { ($0.path, $0) })
    #expect(AdminMeasure.decode(text.joined(separator: "\n")) == expected)
    #expect(AdminMeasure.decode(text.joined(separator: "\r")) == expected)
}

@Test func measureRejectsNonSystemPath() {
    // Not matched by any system rule (a user path, a relative path, a sweep root, a
    // `com.apple.*` system cache): nothing is measured.
    let paths = ["/Users/me/x", "relative/x", "/Library/Caches", "/Library/Caches/com.apple.xyz",
                 "/Users/me/Library/Caches/com.example.app"]
    let lines = AdminMeasure.measureAll(paths, environment: env)
    #expect(lines.map(\.path) == paths)
    #expect(lines.allSatisfy { $0.measurement == nil && $0.error == AdminMeasure.notATarget })
}

@Test func measureAllMeasuresMatchingItemsOnly() throws {
    let t = TempDir(); defer { withExtendedLifetime(t) {} }
    t.file("logs/a.log", bytes: 4096)
    t.file("logs/d/b.log", bytes: 4096)
    t.file("other/c.log", bytes: 4096)
    let rules = [fakeRule(t.url("logs"))]
    let lines = AdminMeasure.measureAll([t.url("logs/a.log"), t.url("logs/d"), t.url("other/c.log"), t.url("logs/gone")],
                                        environment: env, rules: rules)
    #expect(lines[0].measurement?.fileCount == 1 && lines[0].error == nil)
    #expect(lines[1].measurement?.fileCount == 1 && lines[1].measurement?.isDirectory == true)
    #expect(lines[2].measurement == nil && lines[2].error == AdminMeasure.notATarget)
    #expect(lines[3].measurement == nil && lines[3].error == "missing")

    // A rule that doesn't need admin isn't a system target either.
    let user = AdminMeasure.measureAll([t.url("logs/a.log")], environment: env, rules: [fakeRule(t.url("logs"), admin: false)])
    #expect(user[0].measurement == nil && user[0].error == AdminMeasure.notATarget)

    // The never-clean list (taken from the app) denies.
    var e = env
    e.neverClean = [t.url("logs/a.log")]
    let kept = AdminMeasure.measureAll([t.url("logs/a.log")], environment: e, rules: rules)
    #expect(kept[0].measurement == nil && kept[0].error == AdminMeasure.notATarget)
}

@Test func measureAllRefusesPathThroughSymlinkedAncestor() throws {
    let t = TempDir(); defer { withExtendedLifetime(t) {} }
    t.file("real/logs/a.log", bytes: 4096)
    t.symlink("link", to: t.url("real"))
    let lines = AdminMeasure.measureAll([t.url("link/logs/a.log")], environment: env, rules: [fakeRule(t.url("link/logs"))])
    #expect(lines[0].measurement == nil && lines[0].error == AdminMeasure.notATarget)
}

/// Every rule root may act on must be an absolute path, so the `home` the app
/// sends can't widen what root accepts.
@Test func adminRulesAreAbsolute() {
    let admin = CleanCatalog.rules.filter(\.requiresAdmin)
    #expect(!admin.isEmpty)
    #expect(admin.allSatisfy { $0.pattern.hasPrefix("/") })
}
