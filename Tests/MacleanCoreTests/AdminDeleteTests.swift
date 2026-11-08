import Foundation
import Testing
@testable import MacleanCore

private let env = ProtectionEnvironment(home: "/Users/me", appBundle: "/Applications/Maclean.app",
                                        mountPoints: ["/", "/Volumes/Ext"], timeMachineMounts: ["/Volumes/TM"])

private func req(_ path: String, dir: Bool = false) -> DeleteRequest {
    DeleteRequest(path: path, inode: 42, device: 7, size: 4096, fileCount: 1, isDirectory: dir)
}

@Test func argumentsRoundTripThroughItemsFile() throws {
    let items = [
        AdminDelete.Item(request: req("/Users/me/with space/a b"), force: false),
        AdminDelete.Item(request: req("/Users/me/\"quoted\" 'single'", dir: true), force: true),
        AdminDelete.Item(request: req("/Users/me/new\nline"), force: false),
        AdminDelete.Item(request: req("/Users/me/--delete"), force: true),
        AdminDelete.Item(request: req("/Users/me/$(rm -rf ~); `x` \\ é"), force: false),
    ]
    let (file, hash) = try AdminDelete.writeItemsFile(items)
    defer { AdminDelete.removeItemsFile(file) }
    // Private: the file is the owner's only, in a fresh directory of its own.
    let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attrs[.posixPermissions] as? Int) == 0o600)
    let dirAttrs = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
    #expect((dirAttrs[.posixPermissions] as? Int) == 0o700)

    let args = AdminDelete.arguments(itemsFile: file.path, sha256: hash, environment: env, context: .collector)
    #expect(args == ["--delete", "--env", args[2], "--items-file", file.path, "--items-sha256", hash,
                     "--context", "collector"])
    let parsed = try AdminDelete.parse(args)
    #expect(parsed.items == items)
    #expect(parsed.environment == env)

    AdminDelete.removeItemsFile(file)
    #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
}

@Test func contextRoundTrips() throws {
    let (file, hash) = try AdminDelete.writeItemsFile([AdminDelete.Item(request: req("/Users/me/x"), force: false)])
    defer { AdminDelete.removeItemsFile(file) }
    let args = AdminDelete.arguments(itemsFile: file.path, sha256: hash, environment: env, context: .smartClean)
    #expect(Array(args.suffix(2)) == ["--context", "smart-clean"])
    #expect(try AdminDelete.parse(args).context == .smartClean)
}

@Test func parseRejectsUnknownContext() throws {
    let (file, hash) = try AdminDelete.writeItemsFile([AdminDelete.Item(request: req("/Users/me/x"), force: false)])
    defer { AdminDelete.removeItemsFile(file) }
    let good = AdminDelete.arguments(itemsFile: file.path, sha256: hash, environment: env, context: .collector)
    #expect(throws: (any Error).self) { try AdminDelete.parse(Array(good.dropLast()) + ["everything"]) }
    #expect(throws: (any Error).self) { try AdminDelete.parse(Array(good.dropLast(2))) }
    #expect(throws: (any Error).self) { try AdminDelete.parse(Array(good.dropLast(2)) + ["--ctx", "collector"]) }
}

@Test func manyItemsStayOutOfArgv() throws {
    let long = String(repeating: "x", count: 200)
    let items = (0..<5_000).map { AdminDelete.Item(request: req("/Users/me/\(long)/\($0)"), force: false) }
    let (file, hash) = try AdminDelete.writeItemsFile(items)
    defer { AdminDelete.removeItemsFile(file) }
    let args = AdminDelete.arguments(itemsFile: file.path, sha256: hash, environment: env, context: .collector)
    #expect(args.joined().utf8.count < 4096)
    #expect(try AdminDelete.parse(args).items.count == 5_000)
}

@Test func parseRejectsMalformedArguments() throws {
    let (file, hash) = try AdminDelete.writeItemsFile([AdminDelete.Item(request: req("/Users/me/x"), force: false)])
    defer { AdminDelete.removeItemsFile(file) }
    let good = AdminDelete.arguments(itemsFile: file.path, sha256: hash, environment: env, context: .collector)
    #expect(throws: (any Error).self) { try AdminDelete.parse([]) }
    #expect(throws: (any Error).self) { try AdminDelete.parse(Array(good.dropFirst())) }
    #expect(throws: (any Error).self) { try AdminDelete.parse(good + ["extra"]) }
    var garbled = good
    garbled[2] = "not json"
    #expect(throws: (any Error).self) { try AdminDelete.parse(garbled) }
    var missing = good
    missing[4] = file.path + "-missing"
    #expect(throws: (any Error).self) { try AdminDelete.parse(missing) }
    var notJSON = good
    let junk = file.deletingLastPathComponent().appending(path: "junk.json")
    try Data("not json".utf8).write(to: junk)
    notJSON[4] = junk.path
    #expect(throws: (any Error).self) { try AdminDelete.parse(notJSON) }
    var noHash = good
    noHash[5] = "--items-file"
    #expect(throws: (any Error).self) { try AdminDelete.parse(noHash) }
}

@Test func parseRefusesTamperedOrIrregularItemsFile() throws {
    let items = [AdminDelete.Item(request: req("/Users/me/x"), force: false)]
    let (file, hash) = try AdminDelete.writeItemsFile(items)
    defer { AdminDelete.removeItemsFile(file) }
    let dir = file.deletingLastPathComponent()
    let good = AdminDelete.arguments(itemsFile: file.path, sha256: hash, environment: env, context: .collector)
    #expect(try AdminDelete.parse(good).items == items)

    // Rewritten after the hash was taken (as during the password prompt).
    let other = [AdminDelete.Item(request: req("/Users/me/other"), force: true)]
    let (otherFile, _) = try AdminDelete.writeItemsFile(other)
    defer { AdminDelete.removeItemsFile(otherFile) }
    let swapped = try Data(contentsOf: otherFile)
    try swapped.write(to: file)
    #expect(throws: (any Error).self) { try AdminDelete.parse(good) }

    // Replaced by a symlink to a file with matching contents: not followed.
    let original = dir.appending(path: "original.json")
    let (fresh, freshHash) = try AdminDelete.writeItemsFile(items)
    defer { AdminDelete.removeItemsFile(fresh) }
    try FileManager.default.copyItem(at: fresh, to: original)
    let link = dir.appending(path: "link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
    var viaLink = AdminDelete.arguments(itemsFile: link.path, sha256: freshHash, environment: env, context: .collector)
    #expect(throws: (any Error).self) { try AdminDelete.parse(viaLink) }

    // A FIFO is not a regular file (and must not block the helper).
    let fifo = dir.appending(path: "fifo")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    viaLink[4] = fifo.path
    #expect(throws: (any Error).self) { try AdminDelete.parse(viaLink) }
}

@Test func outcomeLinesRoundTrip() {
    let outcomes: [DeleteOutcome] = [
        .deleted(freed: 123), .changedSinceScan(size: 9, fileCount: 3), .replaced, .missing,
        .refused(.homeItself), .needsAdmin(started: true), .needsAdmin(started: false, verified: true), .failed("Bad\nthing \"x\""),
    ]
    var lines: [String] = []
    var expected: [String: DeleteOutcome] = [:]
    for (i, outcome) in outcomes.enumerated() {
        let path = "/Users/me/item \(i)\nnext"
        let line = AdminDelete.encode(path: path, outcome: outcome)
        #expect(!line.contains("\n") && !line.contains("\r"))
        lines.append(line)
        expected[path] = outcome
    }
    lines.insert("garbage {", at: 3)
    lines.append("")
    #expect(AdminDelete.decode(lines.joined(separator: "\n")) == expected)
    // `do shell script` returns output with CR line endings.
    #expect(AdminDelete.decode(lines.joined(separator: "\r")) == expected)
}

/// A request for `path` from a fresh scan of its parent, as the collector would build it.
private func scannedRequest(_ path: String) async throws -> DeleteRequest {
    let tree = try await Scanner.scan(path: (path as NSString).deletingLastPathComponent)
    let id = try #require(tree.node(atPath: path))
    return DeleteRequest(path: path, inode: tree.inode(of: id), device: tree.device(of: id), size: tree.size(of: id),
                         fileCount: tree.fileCount(of: id), isDirectory: tree.flags(of: id).contains(.directory))
}

private func exists(_ path: String) -> Bool {
    var st = stat()
    return lstat(path, &st) == 0
}

@Test func resolvedRefusalCatchesSymlinkedAncestor() throws {
    let t = TempDir(); defer { withExtendedLifetime(t) {} }
    t.file("real/home/keep.txt")
    t.file("real/other/x.txt")
    t.symlink("link", to: t.url("real"))
    var e = env
    e.home = t.url("real/home")

    func verdict(_ path: String) -> Refusal? {
        guard case .success(let fd) = Deleter.openParent(of: path) else { return nil }
        defer { close(fd) }
        return AdminDelete.resolvedRefusal(for: path, parentFD: fd, context: .collector, in: e)
    }
    // The requested path itself looks harmless, but its parent resolves into
    // the protected home folder.
    #expect(ProtectionRules.refusal(for: t.url("link/home"), in: e) == nil)
    #expect(verdict(t.url("link/home")) == .homeItself)
    // An ordinary item, through the link or not, is allowed.
    #expect(verdict(t.url("link/other")) == nil)
    #expect(verdict(t.url("real/other/x.txt")) == nil)
    // The requested path's own verdict still applies.
    #expect(verdict(t.url("real/home")) == .homeItself)
}

@Test func performChecksAndDeletesThroughOneParentFD() async throws {
    let t = TempDir(); defer { withExtendedLifetime(t) {} }
    t.file("real/home/keep.txt", bytes: 4096)
    t.file("real/other/x.txt", bytes: 4096)
    t.symlink("link", to: t.url("real"))
    var e = env
    e.home = t.url("real/home")
    let deleter = Deleter(mode: .permanent, environment: e)

    // Through the symlinked ancestor, the protected home folder is refused and untouched.
    let home = try await scannedRequest(t.url("real/home"))
    let viaLink = DeleteRequest(path: t.url("link/home"), inode: home.inode, device: home.device, size: home.size,
                                fileCount: home.fileCount, isDirectory: true)
    #expect(await AdminDelete.perform(AdminDelete.Item(request: viaLink, force: true), with: deleter)
            == .refused(.homeItself))
    #expect(exists(t.url("real/home/keep.txt")))

    // An allowed item is deleted relative to the checked fd.
    let other = try await scannedRequest(t.url("real/other/x.txt"))
    #expect(await AdminDelete.perform(AdminDelete.Item(request: other, force: false), with: deleter)
            == .deleted(freed: other.size))
    #expect(!exists(t.url("real/other/x.txt")))

    // A missing parent reports missing; a relative path is refused.
    #expect(await AdminDelete.perform(AdminDelete.Item(request: req(t.url("gone/x")), force: false), with: deleter)
            == .missing)
    #expect(await AdminDelete.perform(AdminDelete.Item(request: req("relative/x"), force: false), with: deleter)
            == .refused(.unsafePath))
}

// MARK: - Smart Clean context

/// A system-style rule over a temp folder: each child of `<dir>`, 7 days old.
private func fakeRule(_ dir: String, admin: Bool = true) -> CleanRule {
    CleanRule(id: "test.admin", category: .systemLogs, pattern: dir, unit: .eachChild, ageTiers: [(7, .safe), (30, .safe)],
              requiresAdmin: admin, reason: "test")
}

private let eightDays: TimeInterval = 8 * 86400

@Test func smartCleanPerformRefusesNonCatalogPath() async throws {
    let t = TempDir(); defer { withExtendedLifetime(t) {} }
    t.file("junk/x.txt", bytes: 4096)
    let path = t.url("junk/x.txt")
    // The protection rules alone would let it through: the catalog check is what refuses.
    #expect(ProtectionRules.refusal(for: path, context: .smartClean, in: env) == nil)
    let deleter = Deleter(mode: .permanent, environment: env, context: .smartClean)
    let request = try await scannedRequest(path)
    #expect(await AdminDelete.perform(AdminDelete.Item(request: request, force: true), with: deleter)
            == .refused(.unsafePath))
    #expect(exists(path))
}

@Test func collectorPerformUnaffected() async throws {
    let t = TempDir(); defer { withExtendedLifetime(t) {} }
    t.file("junk/x.txt", bytes: 4096)
    let path = t.url("junk/x.txt")
    let deleter = Deleter(mode: .permanent, environment: env, context: .collector)
    let request = try await scannedRequest(path)
    #expect(await AdminDelete.perform(AdminDelete.Item(request: request, force: false), with: deleter)
            == .deleted(freed: request.size))
    #expect(!exists(path))
}

@Test func smartCleanVerdictChecksRuleAndAge() throws {
    let t = TempDir(); defer { withExtendedLifetime(t) {} }
    t.file("logs/a.log", bytes: 4096)
    let path = t.url("logs/a.log")
    let rules = [fakeRule(t.url("logs"))]

    // Too new for the smallest age tier (7 days): changed since the scan, with root's numbers.
    guard case .changedSinceScan(let size, let files)? =
            AdminDelete.smartCleanVerdict(for: path, rules: rules, home: env.home, now: Date()) else {
        Issue.record("expected changedSinceScan"); return
    }
    #expect(size >= 4096 && files == 1)
    // Old enough.
    #expect(AdminDelete.smartCleanVerdict(for: path, rules: rules, home: env.home, now: Date() + eightDays) == nil)
    // A matching rule that doesn't need admin, or no matching rule: refused.
    #expect(AdminDelete.smartCleanVerdict(for: path, rules: [fakeRule(t.url("logs"), admin: false)], home: env.home,
                                          now: Date() + eightDays) == .refused(.unsafePath))
    #expect(AdminDelete.smartCleanVerdict(for: path, rules: [], home: env.home, now: Date() + eightDays)
            == .refused(.unsafePath))
    #expect(AdminDelete.smartCleanVerdict(for: t.url("logs"), rules: rules, home: env.home, now: Date() + eightDays)
            == .refused(.unsafePath))
    // Gone: missing.
    #expect(AdminDelete.smartCleanVerdict(for: t.url("logs/gone.log"), rules: rules, home: env.home,
                                          now: Date() + eightDays) == .missing)
}

@Test func smartCleanVerdictRefusesPathThroughSymlinkedAncestor() throws {
    let t = TempDir(); defer { withExtendedLifetime(t) {} }
    t.file("real/logs/a.log", bytes: 4096)
    t.symlink("link", to: t.url("real"))
    // The requested path matches the rule as a string, but its parent really is `real/logs`.
    let rules = [fakeRule(t.url("link/logs"))]
    #expect(AdminDelete.smartCleanVerdict(for: t.url("link/logs/a.log"), rules: rules, home: env.home,
                                          now: Date() + eightDays) == .refused(.unsafePath))
}

@Test func smartCleanPerformDeletesOnlyOldCatalogItems() async throws {
    let t = TempDir(); defer { withExtendedLifetime(t) {} }
    t.file("logs/a.log", bytes: 4096)
    let path = t.url("logs/a.log")
    let rules = [fakeRule(t.url("logs"))]
    let deleter = Deleter(mode: .permanent, environment: env, context: .smartClean)
    let item = AdminDelete.Item(request: try await scannedRequest(path), force: false)

    let tooNew = await AdminDelete.perform(item, with: deleter, rules: rules, now: Date(), installed: { [] })
    guard case .changedSinceScan = tooNew else { Issue.record("expected changedSinceScan, got \(tooNew)"); return }
    #expect(exists(path))

    #expect(await AdminDelete.perform(item, with: deleter, rules: rules, now: Date() + eightDays, installed: { [] })
            == .deleted(freed: item.request.size))
    #expect(!exists(path))
}

// MARK: - Root re-checks launchd orphans and file type (R22)

private func plistData(_ dict: [String: Any]) -> Data {
    try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
}

/// A fake helper binary with an embedded Info.plist authorizing `clients`.
private func helperData(clients: [String]) -> Data {
    let reqs = clients.map { "identifier \"\($0)\" and anchor apple generic" }
    return Data([0xCF, 0xFA, 0xED, 0xFE, 0, 1, 2]) + plistData(["CFBundleIdentifier": "com.x.helper",
                                                                 "SMAuthorizedClients": reqs]) + Data([0, 0, 9])
}

private func launchdRule(_ dir: String) -> CleanRule {
    CleanRule(id: "test.launchd", category: .systemServices, pattern: dir + "/*.plist", unit: .folder,
              ageTiers: [(0, .review)], requiresAdmin: true, special: .launchdOrphan, reason: "test")
}

private func helperRule(_ dir: String) -> CleanRule {
    CleanRule(id: "test.helpers", category: .systemServices, pattern: dir, unit: .eachChild,
              ageTiers: [(0, .review)], requiresAdmin: true, special: .launchdOrphan, reason: "test")
}

@Test func rootRechecksLaunchdPlistOrphan() async throws {
    let t = TempDir(); defer { withExtendedLifetime(t) {} }
    t.file("bin/agent")
    t.dir("LaunchDaemons")
    func write(_ name: String, _ data: Data) { try! data.write(to: URL(fileURLWithPath: t.url("LaunchDaemons/\(name)"))) }
    write("com.sec.agent.plist", plistData(["Label": "com.sec.agent", "Program": t.url("bin/agent")]))
    write("com.sec.args.plist", plistData(["Label": "com.sec.args", "ProgramArguments": [t.url("bin/agent"), "-d"]]))
    write("com.gone.plist", plistData(["Label": "com.gone", "ProgramArguments": [t.url("bin/gone")]]))
    write("com.rel.plist", plistData(["Label": "com.rel", "Program": "bin/gone"]))
    write("com.bad.plist", Data("not a plist".utf8))
    t.symlink("LaunchDaemons/com.link.plist", to: t.url("LaunchDaemons/com.gone.plist"))
    let rules = [launchdRule(t.url("LaunchDaemons"))]
    func verdict(_ name: String) -> DeleteOutcome? {
        AdminDelete.smartCleanVerdict(for: t.url("LaunchDaemons/\(name)"), rules: rules, home: env.home, now: Date(),
                                      installed: { [] })
    }
    // Program present, relative, unreadable plist, or a symlink: refused.
    for name in ["com.sec.agent.plist", "com.sec.args.plist", "com.rel.plist", "com.bad.plist", "com.link.plist"] {
        #expect(verdict(name) == .refused(.unsafePath), "\(name)")
    }
    // Program missing: an orphan.
    #expect(verdict("com.gone.plist") == nil)

    // Through perform, a live daemon's plist is refused and left in place; an orphan's is deleted.
    let deleter = Deleter(mode: .permanent, environment: env, context: .smartClean)
    let live = AdminDelete.Item(request: try await scannedRequest(t.url("LaunchDaemons/com.sec.agent.plist")), force: false)
    #expect(await AdminDelete.perform(live, with: deleter, rules: rules, now: Date(), installed: { [] })
            == .refused(.unsafePath))
    #expect(exists(t.url("LaunchDaemons/com.sec.agent.plist")))
    let gone = AdminDelete.Item(request: try await scannedRequest(t.url("LaunchDaemons/com.gone.plist")), force: false)
    #expect(await AdminDelete.perform(gone, with: deleter, rules: rules, now: Date(), installed: { [] })
            == .deleted(freed: gone.request.size))
    #expect(!exists(t.url("LaunchDaemons/com.gone.plist")))
}

@Test func rootRechecksHelperOrphan() throws {
    let t = TempDir(); defer { withExtendedLifetime(t) {} }
    t.dir("Helpers")
    try helperData(clients: ["com.x.app"]).write(to: URL(fileURLWithPath: t.url("Helpers/com.x.helper")))
    try Data([0xCF, 0xFA, 0xED, 0xFE, 1, 2, 3]).write(to: URL(fileURLWithPath: t.url("Helpers/com.y.helper")))
    let rules = [helperRule(t.url("Helpers"))]
    func verdict(_ name: String, _ installed: Set<String>?) -> DeleteOutcome? {
        AdminDelete.smartCleanVerdict(for: t.url("Helpers/\(name)"), rules: rules, home: env.home, now: Date(),
                                      installed: { installed })
    }
    #expect(verdict("com.x.helper", ["com.x.app"]) == .refused(.unsafePath))     // owner installed
    #expect(verdict("com.x.helper", nil) == .refused(.unsafePath))               // couldn't tell
    #expect(verdict("com.x.helper", ["com.other.app"]) == nil)                   // owner gone
    #expect(verdict("com.y.helper", []) == .refused(.unsafePath))                // no owner ids
}

@Test func rootRequiresRegularFileForFileFilterRules() throws {
    let t = TempDir(); defer { withExtendedLifetime(t) {} }
    t.dir("logs/x.log")
    t.file("logs/a.log", bytes: 4096)
    let rules = [CleanRule(id: "test.files", category: .systemLogs, pattern: t.url("logs"), unit: .eachChild,
                           ageTiers: [(7, .safe)], fileFilter: ["*.log"], requiresAdmin: true, reason: "test")]
    func verdict(_ name: String) -> DeleteOutcome? {
        AdminDelete.smartCleanVerdict(for: t.url("logs/\(name)"), rules: rules, home: env.home,
                                      now: Date() + eightDays, installed: { [] })
    }
    #expect(verdict("x.log") == .refused(.unsafePath))
    #expect(exists(t.url("logs/x.log")))
    #expect(verdict("a.log") == nil)
}

@Test func ageCheckFailsWhenItemUnreadable() throws {
    let t = TempDir(); defer { withExtendedLifetime(t) {} }
    t.file("logs/d/a.log")
    t.chmod("logs/d", 0o000)
    let verdict = AdminDelete.smartCleanVerdict(for: t.url("logs/d"), rules: [fakeRule(t.url("logs"))], home: env.home,
                                                now: Date() + eightDays, installed: { [] })
    #expect(verdict == .failed("Couldn't check the item's age"))
}
