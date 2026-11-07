import Foundation
import Testing
@testable import MacleanCore

@Suite(.serialized) struct TreeArchiveTests {
    private func nameBytes(_ tree: FileTree, _ id: NodeID) -> [UInt8] {
        let i = Int(id.index)
        let start = Int(tree.nameOffset[i])
        return Array(tree.names[start ..< Int(tree.nameOffset[i + 1])])
    }

    @Test func roundTripPreservesEverything() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        t.file("a/x", bytes: 8192); t.file("a/b/y", bytes: 4096); t.file("z", bytes: 4096)
        t.file("cafe\u{301} 🎉\nx", bytes: 100)
        t.dir("empty"); t.symlink("link", to: "a/x"); t.hardlink("hl", to: "z")
        let tree = try await Scanner.scan(path: t.path)
        let out = URL(fileURLWithPath: t.url("tree.mcln"))
        try TreeArchive.write(tree, to: out)
        let back = try TreeArchive.read(from: out)

        #expect(back.rootPath == tree.rootPath)
        #expect(abs(back.scanDate.timeIntervalSince(tree.scanDate)) < 1e-3) // 1970-epoch Float64 may differ by an ulp
        #expect(back.count == tree.count)
        for i in 0 ..< tree.count {
            let id = NodeID(index: Int32(i))
            #expect(nameBytes(back, id) == nameBytes(tree, id))
            #expect(Array(back.path(of: id).utf8) == Array(tree.path(of: id).utf8))
            #expect(back.size(of: id) == tree.size(of: id))
            #expect(back.fileCount(of: id) == tree.fileCount(of: id))
            #expect(back.flags(of: id) == tree.flags(of: id))
            #expect(back.inode(of: id) == tree.inode(of: id))
            #expect(back.device(of: id) == tree.device(of: id))
            #expect(back.parent(of: id) == tree.parent(of: id))
            #expect(back.children(of: id) == tree.children(of: id))
        }
        let odd = Array("cafe\u{301} 🎉\nx".utf8)
        #expect((0 ..< tree.count).contains { nameBytes(back, NodeID(index: Int32($0))) == odd })
    }

    @Test func rejectsWrongMagic() throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        let url = URL(fileURLWithPath: t.url("bad"))
        try Data("NOPE0000000000000000000000000000".utf8).write(to: url)
        #expect(throws: ArchiveError.badMagic) { try TreeArchive.read(from: url) }
    }

    @Test func rejectsTruncatedFile() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        t.file("a/x", bytes: 4096)
        let tree = try await Scanner.scan(path: t.path)
        let url = URL(fileURLWithPath: t.url("tree.mcln"))
        try TreeArchive.write(tree, to: url)
        let full = try Data(contentsOf: url)
        for len in [0, 3, 20, full.count - 1] {
            try full.prefix(len).write(to: url)
            #expect(throws: ArchiveError.truncated) { try TreeArchive.read(from: url) }
        }
    }

    @Test func rejectsHugeCountWithoutAllocating() throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        var d = Data("MCLN".utf8)
        d.append(contentsOf: [2, 0, 0, 0])
        d.append(contentsOf: [UInt8](repeating: 0xFF, count: 8)) // absurd node count
        d.append(Data(count: 32))
        let url = URL(fileURLWithPath: t.url("huge"))
        try d.write(to: url)
        #expect(throws: ArchiveError.truncated) { try TreeArchive.read(from: url) }
    }

    @Test func rejectsUnsupportedVersion() throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        var d = Data("MCLN".utf8)
        d.append(contentsOf: [9, 0, 0, 0]); d.append(Data(count: 40))
        let url = URL(fileURLWithPath: t.url("v9"))
        try d.write(to: url)
        #expect(throws: ArchiveError.unsupportedVersion(9)) { try TreeArchive.read(from: url) }
    }

    /// Archive v2 column order after the header.
    private enum Column: Int { case parents, firstChild, childCount, sizes, flagBits, inodes, devices, nameOffset }

    private func columnOffset(_ tree: FileTree, _ column: Column) -> Int {
        let n = tree.count
        let sizes: [Int] = [4 * n, 4 * n, 4 * n, 8 * n, 2 * n, 8 * n, 4 * n, 4 * (n + 1)]
        return 28 + tree.rootPath.utf8.count + sizes[..<column.rawValue].reduce(0, +)
    }

    /// Writes a valid archive for a small tree, then patches one 32-bit value in `column`
    /// at node `index` (counted from the end when `fromEnd` is set).
    private func corrupted(_ t: TempDir, column: Column, index: Int, value: Int32,
                           fromEnd: Bool = false) async throws -> URL {
        t.file("a/x", bytes: 10); t.file("b", bytes: 10)
        let tree = try await Scanner.scan(path: t.path)
        let url = URL(fileURLWithPath: t.url("tree.mcln"))
        try TreeArchive.write(tree, to: url)
        var d = try Data(contentsOf: url)
        let slot = fromEnd ? tree.nameOffset.count - 1 - index : index
        let off = columnOffset(tree, column) + slot * 4
        withUnsafeBytes(of: value.littleEndian) { d.replaceSubrange(off ..< off + 4, with: $0) }
        try d.write(to: url)
        return url
    }

    @Test func rejectsParentCycle() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        let url = try await corrupted(t, column: .parents, index: 1, value: 2)
        #expect(throws: ArchiveError.truncated) { try TreeArchive.read(from: url) }
    }

    @Test func rejectsSelfParent() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        let url = try await corrupted(t, column: .parents, index: 1, value: 1)
        #expect(throws: ArchiveError.truncated) { try TreeArchive.read(from: url) }
    }

    @Test func rejectsBackwardsChildRange() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        let url = try await corrupted(t, column: .firstChild, index: 0, value: 0)
        #expect(throws: ArchiveError.truncated) { try TreeArchive.read(from: url) }
    }

    @Test func rejectsEmptyTree() throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        var d = Data("MCLN".utf8)
        d.append(contentsOf: [2, 0, 0, 0])
        d.append(Data(count: 8 + 8 + 4)) // n = 0, date, rootLen = 0
        d.append(Data(count: 8))         // names count = 0
        let url = URL(fileURLWithPath: t.url("empty"))
        try d.write(to: url)
        #expect(throws: ArchiveError.truncated) { try TreeArchive.read(from: url) }
    }

    @Test func rejectsNonZeroFirstNameOffset() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        let url = try await corrupted(t, column: .nameOffset, index: 0, value: 1)
        #expect(throws: ArchiveError.truncated) { try TreeArchive.read(from: url) }
    }

    @Test func rejectsDecreasingNameOffset() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        // nameOffset[n - 1] past the sentinel nameOffset[n] == names.count.
        let url = try await corrupted(t, column: .nameOffset, index: 1, value: 1_000, fromEnd: true)
        #expect(throws: ArchiveError.truncated) { try TreeArchive.read(from: url) }
    }

    @Test func rejectsNameSentinelMismatch() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        let url = try await corrupted(t, column: .nameOffset, index: 0, value: 0, fromEnd: true)
        #expect(throws: ArchiveError.truncated) { try TreeArchive.read(from: url) }
    }

    @Test func archiveV1IsRejected() throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        var d = Data("MCLN".utf8)
        d.append(contentsOf: [1, 0, 0, 0]); d.append(Data(count: 40))
        let url = URL(fileURLWithPath: t.url("v1"))
        try d.write(to: url)
        #expect(throws: ArchiveError.unsupportedVersion(1)) { try TreeArchive.read(from: url) }
    }
}
