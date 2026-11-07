import Foundation
import Testing
@testable import MacleanCore

private let env = ProtectionEnvironment(home: "/Users/me", appBundle: "/Applications/Maclean.app",
                                        mountPoints: ["/", "/Volumes/Ext"], timeMachineMounts: ["/Volumes/TM"])

private func req(_ path: String, dir: Bool = false) -> DeleteRequest {
    DeleteRequest(path: path, inode: 42, device: 7, size: 4096, fileCount: 1, isDirectory: dir)
}

@Test func argumentsRoundTrip() throws {
    let items = [
        AdminDelete.Item(request: req("/Users/me/with space/a b"), force: false),
        AdminDelete.Item(request: req("/Users/me/\"quoted\" 'single'", dir: true), force: true),
        AdminDelete.Item(request: req("/Users/me/new\nline"), force: false),
        AdminDelete.Item(request: req("/Users/me/--delete"), force: true),
        AdminDelete.Item(request: req("/Users/me/$(rm -rf ~); `x` \\ é"), force: false),
    ]
    let args = AdminDelete.arguments(items: items, environment: env)
    #expect(args.first == "--delete")
    #expect(args.count == 5)
    let parsed = try AdminDelete.parse(args)
    #expect(parsed.items == items)
    #expect(parsed.environment == env)
}

@Test func parseRejectsMalformedArguments() {
    let good = AdminDelete.arguments(items: [AdminDelete.Item(request: req("/Users/me/x"), force: false)],
                                     environment: env)
    #expect(throws: (any Error).self) { try AdminDelete.parse([]) }
    #expect(throws: (any Error).self) { try AdminDelete.parse(Array(good.dropFirst())) }
    #expect(throws: (any Error).self) { try AdminDelete.parse(good + ["extra"]) }
    var garbled = good
    garbled[4] = "not json"
    #expect(throws: (any Error).self) { try AdminDelete.parse(garbled) }
}

@Test func outcomeLinesRoundTrip() {
    let outcomes: [DeleteOutcome] = [
        .deleted(freed: 123), .changedSinceScan(size: 9, fileCount: 3), .replaced, .missing,
        .refused(.homeItself), .needsAdmin(started: true), .failed("Bad\nthing \"x\""),
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
        return AdminDelete.resolvedRefusal(for: path, parentFD: fd, in: e)
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
