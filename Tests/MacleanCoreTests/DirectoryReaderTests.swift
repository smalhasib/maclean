import Foundation
import Testing
@testable import MacleanCore

@Suite struct DirectoryReaderTests {
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
