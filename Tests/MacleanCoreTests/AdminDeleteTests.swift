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

@Test func resolvedRefusalCatchesSymlinkedAncestor() {
    let t = TempDir(); defer { withExtendedLifetime(t) {} }
    t.file("real/home/keep.txt")
    t.file("real/other/x.txt")
    t.symlink("link", to: t.url("real"))
    var e = env
    e.home = t.url("real/home")

    // The requested path itself looks harmless, but its parent resolves into
    // the protected home folder.
    #expect(ProtectionRules.refusal(for: t.url("link/home"), in: e) == nil)
    #expect(AdminDelete.resolvedRefusal(for: t.url("link/home"), in: e) == .homeItself)
    // An ordinary item, through the link or not, is allowed.
    #expect(AdminDelete.resolvedRefusal(for: t.url("link/other"), in: e) == nil)
    #expect(AdminDelete.resolvedRefusal(for: t.url("real/other/x.txt"), in: e) == nil)
    // The requested path's own verdict still applies.
    #expect(AdminDelete.resolvedRefusal(for: t.url("real/home"), in: e) == .homeItself)
    #expect(AdminDelete.resolvedRefusal(for: "relative/x", in: e) == .unsafePath)
    // A missing parent is left to the deleter (it reports .missing).
    #expect(AdminDelete.resolvedRefusal(for: t.url("gone/x"), in: e) == nil)
}
