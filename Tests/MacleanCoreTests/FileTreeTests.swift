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
