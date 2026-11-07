import Foundation
import Testing
@testable import MacleanCore

@Test func sizesSumAndChildrenSortDescending() {
    let b = FileTreeBuilder(rootPath: "/r", rootInode: 1, rootDevice: 1)
    let a = b.add(parent: b.root, name: "a", size: 0, flags: .directory, inode: 2, device: 1)
    b.add(parent: a, name: "small", size: 10, flags: [], inode: 3, device: 1)
    b.add(parent: a, name: "big", size: 300, flags: [], inode: 4, device: 1)
    b.add(parent: b.root, name: "f", size: 50, flags: [], inode: 5, device: 1)
    let t = b.finish()
    #expect(t.size(of: t.root) == 360)
    #expect(t.children(of: t.root).map { t.name(of: $0) } == ["a", "f"])
    let aID = t.children(of: t.root)[0]
    #expect(t.children(of: aID).map { t.name(of: $0) } == ["big", "small"])
    #expect(t.path(of: t.children(of: aID)[0]) == "/r/a/big")
    #expect(t.fileCount(of: t.root) == 3)
    #expect(t.parent(of: aID) == t.root && t.parent(of: t.root) == nil)
    #expect(t.count == 5)
    #expect(t.path(of: t.root) == "/r")
    #expect(t.inode(of: aID) == 2 && t.device(of: aID) == 1)
    #expect(t.flags(of: aID).contains(.directory))
}

@Test func equalSizesSortByName() {
    let b = FileTreeBuilder(rootPath: "/r", rootInode: 1, rootDevice: 1)
    b.add(parent: b.root, name: "b", size: 5, flags: [], inode: 2, device: 1)
    b.add(parent: b.root, name: "a", size: 5, flags: [], inode: 3, device: 1)
    let t = b.finish()
    #expect(t.children(of: t.root).map { t.name(of: $0) } == ["a", "b"])
}

@Test func oddNamesRoundTripExactly() {
    let odd = "cafe\u{301} 🎉\nx"
    let b = FileTreeBuilder(rootPath: "/r", rootInode: 1, rootDevice: 1)
    b.add(parent: b.root, name: odd, size: 1, flags: [], inode: 2, device: 1)
    let t = b.finish()
    let id = t.children(of: t.root)[0]
    #expect(Array(t.name(of: id).utf8) == Array(odd.utf8))
    #expect(Array(t.path(of: id).utf8) == Array(("/r/" + odd).utf8))
}

@Test func canonicallyEquivalentNamesStayDistinct() {
    let decomposed = "cafe\u{301}"
    let precomposed = "caf\u{e9}"
    let b = FileTreeBuilder(rootPath: "/r", rootInode: 1, rootDevice: 1)
    b.add(parent: b.root, name: decomposed, size: 1, flags: [], inode: 2, device: 1)
    b.add(parent: b.root, name: precomposed, size: 1, flags: [], inode: 3, device: 1)
    let t = b.finish()
    let kids = t.children(of: t.root)
    #expect(kids.count == 2)
    let got = Set(kids.map { Array(t.name(of: $0).utf8) })
    #expect(got == [Array(decomposed.utf8), Array(precomposed.utf8)])
}

@Test func pathJoinsWithoutDoubledSlash() {
    for (root, expected) in [("/", "/Users"), ("/foo/", "/foo/Users"), ("/foo", "/foo/Users")] {
        let b = FileTreeBuilder(rootPath: root, rootInode: 1, rootDevice: 1)
        b.add(parent: b.root, name: "Users", size: 1, flags: [], inode: 2, device: 1)
        let t = b.finish()
        #expect(t.path(of: t.children(of: t.root)[0]) == expected)
        #expect(t.path(of: t.root) == root)
    }
}

@Test func restrictedFlagIsKept() {
    let b = FileTreeBuilder(rootPath: "/r", rootInode: 1, rootDevice: 1)
    let d = b.add(parent: b.root, name: "d", size: 0, flags: .directory, inode: 2, device: 1)
    b.markRestricted(d)
    let t = b.finish()
    #expect(t.flags(of: t.children(of: t.root)[0]).contains(.restricted))
}

@Test func steadyStateIsCompact() {
    let b = FileTreeBuilder(rootPath: "/r", rootInode: 1, rootDevice: 1)
    for i in 0 ..< 100_000 {
        b.add(parent: b.root, name: String(format: "f%09d", i), size: Int64(i), flags: [],
              inode: UInt64(i + 2), device: 1)
    }
    let t = b.finish()
    // 38 B of columns + 10-byte names (+ sentinel slack).
    #expect(Double(t.storageBytes) / Double(t.count) <= 40 + 10 + 1)
}

@Test func fileCountIsComputed() {
    let b = FileTreeBuilder(rootPath: "/r", rootInode: 1, rootDevice: 1)
    let a = b.add(parent: b.root, name: "a", size: 0, flags: .directory, inode: 2, device: 1)
    let c = b.add(parent: a, name: "c", size: 0, flags: .directory, inode: 3, device: 1)
    b.add(parent: c, name: "x", size: 1, flags: [], inode: 4, device: 1)
    b.add(parent: a, name: "y", size: 1, flags: [], inode: 5, device: 1)
    b.add(parent: b.root, name: "z", size: 1, flags: .symlink, inode: 6, device: 1)
    b.add(parent: b.root, name: "e", size: 0, flags: .directory, inode: 7, device: 1)
    let t = b.finish()
    let byName = Dictionary(uniqueKeysWithValues: (0 ..< t.count).map {
        (t.name(of: NodeID(index: Int32($0))), NodeID(index: Int32($0)))
    })
    #expect(t.fileCount(of: t.root) == 3)
    #expect(t.fileCount(of: byName["a"]!) == 2)
    #expect(t.fileCount(of: byName["c"]!) == 1)
    #expect(t.fileCount(of: byName["x"]!) == 1)
    #expect(t.fileCount(of: byName["e"]!) == 0)
}

@Test func namesAreInBFSOrder() {
    // Append order (root, d1, d1/deep, d1/deep/leaf, d2, d2/k) differs from BFS order
    // (root, d2, d1, d2/k, d1/deep, d1/deep/leaf) because d2 is larger than d1.
    let b = FileTreeBuilder(rootPath: "/r", rootInode: 1, rootDevice: 1)
    let d1 = b.add(parent: b.root, name: "d1", size: 0, flags: .directory, inode: 2, device: 1)
    let deep = b.add(parent: d1, name: "deep-é", size: 0, flags: .directory, inode: 3, device: 1)
    b.add(parent: deep, name: "leaf 🎉", size: 5, flags: [], inode: 4, device: 1)
    let d2 = b.add(parent: b.root, name: "d2", size: 0, flags: .directory, inode: 5, device: 1)
    b.add(parent: d2, name: "k", size: 50, flags: [], inode: 6, device: 1)
    let t = b.finish()

    let expected = ["", "d2", "d1", "k", "deep-é", "leaf 🎉"]
    #expect(t.count == expected.count)
    #expect(t.nameOffset.count == t.count + 1)
    #expect(t.nameOffset.first == 0 && t.nameOffset.last == UInt32(t.names.count))
    #expect(zip(t.nameOffset, t.nameOffset.dropFirst()).allSatisfy { $0 <= $1 })
    for (i, name) in expected.enumerated() {
        #expect(Array(t.name(of: NodeID(index: Int32(i))).utf8) == Array(name.utf8))
    }
    // The names buffer itself is laid out in BFS order.
    #expect(t.names == Array(expected.joined().utf8))
    #expect(t.path(of: NodeID(index: 5)) == "/r/d1/deep-é/leaf 🎉")
}

@Test func rootOnlyTreeFinishes() {
    let t = FileTreeBuilder(rootPath: "/r", rootInode: 1, rootDevice: 1).finish()
    #expect(t.count == 1 && t.children(of: t.root).isEmpty && t.name(of: t.root) == "")
    #expect(t.fileCount(of: t.root) == 0 && t.nameOffset == [0, 0])
}

@Test func namesAndColumnsSpanStagingChunks() {
    // Tiny 8-element staging chunks: node columns and name bytes cross many chunk
    // boundaries, and the two-level shape makes BFS order differ from append order.
    let b = FileTreeBuilder(rootPath: "/r", rootInode: 1, rootDevice: 1, chunkShift: 3)
    var dirs: [NodeID] = []
    for d in 0 ..< 3 {
        dirs.append(b.add(parent: b.root, name: "dir\(d)", size: 0, flags: .directory,
                          inode: UInt64(d + 2), device: 1))
    }
    let perDir = 300
    for d in 0 ..< 3 {
        for i in 0 ..< perDir {
            b.add(parent: dirs[d], name: "n\(d)-\(i)", size: Int64(i % 7 + d), flags: [],
                  inode: UInt64(10 + d * perDir + i), device: Int32(d))
        }
    }
    let t = b.finish()
    #expect(t.count == 1 + 3 + 3 * perDir)
    #expect(t.fileCount(of: t.root) == Int64(3 * perDir))
    #expect(t.children(of: t.root).map { t.name(of: $0) } == ["dir2", "dir1", "dir0"])
    for dir in t.children(of: t.root) {
        let d = Int(t.name(of: dir).dropFirst(3))!
        let kids = t.children(of: dir)
        #expect(kids.count == perDir)
        #expect(t.size(of: dir) == kids.reduce(0) { $0 + t.size(of: $1) })
        let keys = kids.map { (t.size(of: $0), Array(t.name(of: $0).utf8)) }
        #expect(zip(keys, keys.dropFirst()).allSatisfy { a, b in
            a.0 > b.0 || (a.0 == b.0 && a.1.lexicographicallyPrecedes(b.1))
        })
        #expect(kids.allSatisfy { kid in
            let i = Int(t.name(of: kid).split(separator: "-")[1])!
            return t.inode(of: kid) == UInt64(10 + d * perDir + i) && t.device(of: kid) == Int32(d)
                && t.size(of: kid) == Int64(i % 7 + d) && t.parent(of: kid) == dir
        })
    }
}
