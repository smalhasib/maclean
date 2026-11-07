import Foundation
import Testing
@testable import MacleanCore

/// A protection environment that refuses nothing inside a TempDir.
private let env = ProtectionEnvironment(home: "/Users/maclean-test-nobody", appBundle: "/Applications/Maclean.app",
                                        mountPoints: [], timeMachineMounts: [])

private func exists(_ path: String) -> Bool {
    var st = stat()
    return lstat(path, &st) == 0
}

/// A request for `path` built from a fresh scan of its parent, as the collector would.
private func request(_ path: String) async throws -> DeleteRequest {
    let parent = (path as NSString).deletingLastPathComponent
    let tree = try await Scanner.scan(path: parent)
    let id = try #require(tree.node(atPath: path))
    return DeleteRequest(path: path, inode: tree.inode(of: id), device: tree.device(of: id),
                         size: tree.size(of: id), fileCount: tree.fileCount(of: id),
                         isDirectory: tree.flags(of: id).contains(.directory))
}

/// Whether `FileManager.trashItem` works here (probed on a TempDir file, removed again from the Trash).
private func trashWorks() -> Bool {
    let t = TempDir(); defer { withExtendedLifetime(t) {} }
    t.file("probe-\(UUID().uuidString)")
    let probe = try! FileManager.default.contentsOfDirectory(atPath: t.path)[0]
    var result: NSURL?
    guard (try? FileManager.default.trashItem(at: URL(fileURLWithPath: t.url(probe)), resultingItemURL: &result)) != nil,
          let url = result as URL? else { return false }
    try? FileManager.default.removeItem(at: url)
    return true
}

private final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URL?
    var url: URL? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@Suite(.serialized) struct DeleterTests {
    let deleter = Deleter(mode: .permanent, environment: env)

    @Test func deletesFileAndFolderPermanently() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        t.file("f", bytes: 8192)
        t.file("d/a", bytes: 4096); t.file("d/sub/b", bytes: 4096); t.dir("d/empty")
        let rf = try await request(t.url("f")), rd = try await request(t.url("d"))
        #expect(await deleter.delete(rf) == .deleted(freed: rf.size))
        #expect(await deleter.delete(rd) == .deleted(freed: rd.size))
        #expect(!exists(t.url("f")) && !exists(t.url("d")))
        #expect(rd.size > 0 && rd.fileCount == 2)
    }

    @Test func missingReportsMissing() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        t.file("f", bytes: 10)
        let r = try await request(t.url("f"))
        try FileManager.default.removeItem(atPath: t.url("f"))
        #expect(await deleter.delete(r) == .missing)
    }

    @Test func replacedIsNeverDeleted() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        t.file("f", bytes: 10); t.file("hold", bytes: 10)   // "hold" keeps the old inode from being reused at once
        let r = try await request(t.url("f"))
        try FileManager.default.removeItem(atPath: t.url("f"))
        t.file("f", bytes: 10)
        #expect(await deleter.delete(r) == .replaced)
        #expect(exists(t.url("f")))
    }

    @Test func changedFolderIsReported() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        t.file("d/a", bytes: 4096)
        let r = try await request(t.url("d"))
        for i in 0..<3 { t.file("d/new\(i)") }
        guard case let .changedSinceScan(size, fileCount) = await deleter.delete(r) else {
            Issue.record("expected changedSinceScan"); return
        }
        #expect(fileCount == r.fileCount + 3)
        #expect(size >= r.size)
        #expect(exists(t.url("d/a")) && exists(t.url("d/new2")))
        #expect(await deleter.delete(r, force: true) == .deleted(freed: r.size))
        #expect(!exists(t.url("d")))
    }

    @Test func smallCacheChurnIsNotChange() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        for i in 0..<5 { t.file("d/big\(i)", bytes: 10 << 20) }
        t.file("d/small", bytes: 10 << 10)
        let r = try await request(t.url("d"))
        try Data(repeating: 1, count: 12 << 10).write(to: URL(fileURLWithPath: t.url("d/small")))
        guard case .deleted = await deleter.delete(r) else { Issue.record("expected deleted"); return }
        #expect(!exists(t.url("d")))
    }

    @Test func symlinkIsDeletedAsLinkOnly() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        t.file("keep/k", bytes: 10)
        t.symlink("link", to: t.url("keep"))
        let r = try await request(t.url("link"))
        #expect(!r.isDirectory)
        guard case .deleted = await deleter.delete(r) else { Issue.record("expected deleted"); return }
        #expect(!exists(t.url("link")))
        #expect(exists(t.url("keep/k")))
    }

    @Test func symlinkSwappedInsideTreeIsNotFollowed() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        t.file("keep/k", bytes: 10)
        t.file("item/sub/a", bytes: 10); t.file("item/b", bytes: 10)
        let r = try await request(t.url("item"))
        try FileManager.default.removeItem(atPath: t.url("item/sub"))
        t.symlink("item/sub", to: t.url("keep"))
        #expect(await deleter.delete(r, force: true) == .deleted(freed: r.size))
        #expect(!exists(t.url("item")))
        #expect(exists(t.url("keep/k")))
    }

    @Test func refusedPathsAreRefused() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        t.file("x", bytes: 10)
        let home = ProtectionEnvironment(home: t.path, appBundle: "/Applications/Maclean.app",
                                         mountPoints: [], timeMachineMounts: [])
        let r = DeleteRequest(path: t.path, inode: 0, device: 0, size: 0, fileCount: 1, isDirectory: true)
        #expect(await Deleter(mode: .permanent, environment: home).delete(r, force: true) == .refused(.homeItself))
        #expect(exists(t.url("x")))
    }

    @Test func permissionDeniedNeedsAdmin() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        t.file("p/f", bytes: 10)
        let r = try await request(t.url("p/f"))
        t.chmod("p", 0o500)
        #expect(await deleter.delete(r) == .needsAdmin(started: false))
        #expect(exists(t.url("p/f")))
    }

    @Test func permissionDeniedMidTreeReportsStarted() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        t.file("d/a/x", bytes: 10); t.file("d/b/y", bytes: 10)
        let r = try await request(t.url("d"))
        t.chmod("d/b", 0o500)
        // Children are removed in name order, so d/a goes before d/b fails.
        #expect(await deleter.delete(r, force: true) == .needsAdmin(started: true))
        #expect(exists(t.url("d/b/y")))
    }

    @Test(.enabled(if: trashWorks(), "FileManager.trashItem is unavailable in this environment"))
    func trashModeMovesToTrash() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        let name = "maclean-trash-test-\(UUID().uuidString)"
        t.file(name, bytes: 10)
        let r = try await request(t.url(name))
        let box = URLBox()
        let trasher = Deleter(mode: .trash, environment: env, trashed: { box.url = $0 })
        let outcome = await trasher.delete(r)
        if let url = box.url { try? FileManager.default.removeItem(at: url) }
        #expect(outcome == .deleted(freed: r.size))
        #expect(box.url != nil)
        #expect(!exists(t.url(name)))
    }

    @Test func treeWithMountPointIsAnotherDisk() {
        let b = FileTreeBuilder(rootPath: "/r", rootInode: 1, rootDevice: 1)
        let a = b.add(parent: b.root, name: "a", size: 0, flags: .directory, inode: 2, device: 1)
        b.add(parent: a, name: "Ext", size: 0, flags: [.directory, .mountPoint], inode: 3, device: 2)
        #expect(Deleter.otherDisk(in: b.finish()) == "Ext")

        let c = FileTreeBuilder(rootPath: "/r", rootInode: 1, rootDevice: 1)
        c.add(parent: c.root, name: "a", size: 0, flags: .directory, inode: 2, device: 1)
        #expect(Deleter.otherDisk(in: c.finish()) == nil)
    }

    @Test func outcomeForTreeRejectsOtherDiskAndRestricted() {
        let r = DeleteRequest(path: "/r", inode: 1, device: 1, size: 0, fileCount: 0, isDirectory: true)
        let b = FileTreeBuilder(rootPath: "/r", rootInode: 1, rootDevice: 1)
        b.add(parent: b.root, name: "Ext", size: 0, flags: [.directory, .mountPoint], inode: 3, device: 2)
        #expect(Deleter.rewalkVerdict(r, tree: b.finish()) == .failed("Contains another disk: Ext"))

        let c = FileTreeBuilder(rootPath: "/r", rootInode: 1, rootDevice: 1)
        let locked = c.add(parent: c.root, name: "locked", size: 0, flags: .directory, inode: 3, device: 1)
        c.markRestricted(locked)
        #expect(Deleter.rewalkVerdict(r, tree: c.finish()) == .needsAdmin(started: false))

        let d = FileTreeBuilder(rootPath: "/r", rootInode: 1, rootDevice: 1)
        #expect(Deleter.rewalkVerdict(r, tree: d.finish()) == nil)
    }
}
