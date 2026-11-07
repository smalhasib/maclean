import Foundation
import Testing
@testable import MacleanCore

/// A real mount point on this machine whose parent can be listed, if any.
private let knownMountPoint: (parent: String, name: String)? = {
    for (parent, name) in [("/System/Volumes", "VM"), ("/System/Volumes", "Preboot"), ("/", "dev")] {
        var a = stat(), b = stat()
        let path = parent == "/" ? "/" + name : parent + "/" + name
        if stat(parent, &a) == 0, stat(path, &b) == 0, a.st_dev != b.st_dev { return (parent, name) }
    }
    return nil
}()

@Suite struct DirectoryReaderTests {
    @Test(.enabled(if: knownMountPoint != nil)) func reportsMountPoint() throws {
        let (parent, name) = try #require(knownMountPoint)
        let h = try DirectoryReader.open(path: parent)
        let e = try #require(try DirectoryReader.entries(of: h).first { $0.name == name })
        #expect(e.kind == .directory)
        #expect(e.isMountPoint)
    }

    @Test func ordinaryEntriesAreNotMountPoints() throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        t.file("a.bin", bytes: 100); t.dir("sub"); t.symlink("ln", to: "sub")
        let h = try DirectoryReader.open(path: t.path)
        let e = try DirectoryReader.entries(of: h)
        #expect(e.count == 3)
        #expect(e.allSatisfy { !$0.isMountPoint })
    }

    @Test func listsFilesDirsAndSymlinks() throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        t.file("a.bin", bytes: 10_000); t.dir("sub"); t.symlink("ln", to: "sub")
        let h = try DirectoryReader.open(path: t.path)
        let e = try DirectoryReader.entries(of: h).sorted { $0.name < $1.name }
        #expect(e.map(\.name) == ["a.bin", "ln", "sub"])
        #expect(e.map(\.kind) == [.file, .symlink, .directory])
        #expect(e[0].allocatedSize >= 10_000 && e[0].inode != 0 && e[0].linkCount == 1)
        #expect(e[2].allocatedSize == 0)
    }

    @Test func matchesLstat() throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        t.file("a.bin", bytes: 10_000); t.dir("sub"); t.symlink("ln", to: "sub")
        let h = try DirectoryReader.open(path: t.path)
        for e in try DirectoryReader.entries(of: h) {
            var st = stat()
            #expect(lstat(t.url(e.name), &st) == 0)
            #expect(e.inode == st.st_ino, "\(e.name)")
            #expect(e.device == st.st_dev, "\(e.name)")
            if e.kind != .directory {
                #expect(e.linkCount == UInt32(st.st_nlink), "\(e.name)")
                #expect(e.allocatedSize == Int64(st.st_blocks) * 512, "\(e.name)")
            }
        }
    }

    @Test func hardLinkReportsLinkCount() throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        t.file("a", bytes: 100); t.hardlink("b", to: "a")
        let h = try DirectoryReader.open(path: t.path)
        let e = try DirectoryReader.entries(of: h).sorted { $0.name < $1.name }
        #expect(e.map(\.name) == ["a", "b"])
        #expect(e.allSatisfy { $0.linkCount == 2 })
        #expect(e[0].inode == e[1].inode)
    }

    @Test func clonesShareCloneID() throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        t.file("orig", bytes: 50_000)
        guard clonefile(t.url("orig"), t.url("copy"), 0) == 0 else { return }  // volume without clone support
        let h = try DirectoryReader.open(path: t.path)
        let e = try DirectoryReader.entries(of: h).sorted { $0.name < $1.name }
        #expect(e.map(\.name) == ["copy", "orig"])
        #expect(e[0].cloneID != 0 && e[0].cloneID == e[1].cloneID)
        #expect(e[0].cloneRefCount == 2 && e[1].cloneRefCount == 2)
        #expect(e[0].inode != e[1].inode)
    }

    @Test func missingPathThrowsNotFound() {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        #expect(throws: ReadError.notFound) { _ = try DirectoryReader.open(path: t.path + "/nope") }
    }

    @Test func fileIsNotADirectory() throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        t.file("f")
        #expect(throws: ReadError.notDirectory) { _ = try DirectoryReader.open(path: t.url("f")) }
        let h = try DirectoryReader.open(path: t.path)
        #expect(throws: ReadError.notDirectory) { _ = try DirectoryReader.open(name: "f", in: h) }
    }

    @Test func openRelativeToParent() throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        t.file("sub/x"); t.file("sub/y")
        let h = try DirectoryReader.open(path: t.path)
        let s = try DirectoryReader.open(name: "sub", in: h)
        #expect(try DirectoryReader.entries(of: s).map(\.name).sorted() == ["x", "y"])
    }

    @Test func openPathFollowsSymlinkedRoot() throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        t.file("real/x"); t.file("real/y"); t.symlink("link", to: "real")
        let h = try DirectoryReader.open(path: t.url("link"))
        #expect(try DirectoryReader.entries(of: h).map(\.name).sorted() == ["x", "y"])
    }

    @Test func openNameDoesNotFollowSymlink() throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        t.dir("real"); t.symlink("link", to: "real")
        let h = try DirectoryReader.open(path: t.path)
        #expect(throws: ReadError.self) { _ = try DirectoryReader.open(name: "link", in: h) }
    }

    @Test func unreadableDirThrowsPermissionDenied() throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        t.file("sub/x"); t.chmod("sub", 0o000)
        let h = try DirectoryReader.open(path: t.path)
        #expect(throws: ReadError.permissionDenied) {
            let s = try DirectoryReader.open(name: "sub", in: h)
            _ = try DirectoryReader.entries(of: s)
        }
    }

    @Test func readsManyEntries() throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        for i in 0..<5_000 { t.file("file-with-a-longish-name-\(i)") }
        let h = try DirectoryReader.open(path: t.path)
        let e = try DirectoryReader.entries(of: h)
        #expect(e.count == 5_000)
        #expect(Set(e.map(\.name)).count == 5_000)
        #expect(e.allSatisfy { $0.kind == .file })
    }
}
