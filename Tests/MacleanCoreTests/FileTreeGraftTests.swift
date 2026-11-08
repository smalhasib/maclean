import Foundation
import Testing
@testable import MacleanCore

/// root/a (restricted, empty), root/b (dir with f:30), root/c (file 10).
private func baseTree() -> FileTree {
    let b = FileTreeBuilder(rootPath: "/r", rootInode: 1, rootDevice: 1)
    let a = b.add(parent: b.root, name: "a", size: 0, flags: [.directory, .restricted], inode: 2, device: 1)
    _ = a
    let bDir = b.add(parent: b.root, name: "b", size: 0, flags: .directory, inode: 3, device: 1)
    b.add(parent: bDir, name: "f", size: 30, flags: .hardLinkFirst, inode: 4, device: 1)
    b.add(parent: b.root, name: "c", size: 10, flags: [], inode: 5, device: 1)
    return b.finish()
}

/// /r/a read as root: x:100, y:50, and an inner restricted folder z.
private func subtreeA(rootPath: String = "/r/a") -> FileTree {
    let b = FileTreeBuilder(rootPath: rootPath, rootInode: 2, rootDevice: 1)
    b.add(parent: b.root, name: "x", size: 100, flags: [], inode: 10, device: 1)
    b.add(parent: b.root, name: "y", size: 50, flags: .cloneExtra, inode: 11, device: 1)
    b.add(parent: b.root, name: "z", size: 0, flags: [.directory, .restricted], inode: 12, device: 1)
    return b.finish()
}

@Test func graftFillsRestrictedNode() throws {
    let tree = baseTree()
    #expect(tree.size(of: tree.root) == 40)
    let grafted = tree.grafting(["/r/a": subtreeA()])

    let a = try #require(grafted.node(atPath: "/r/a"))
    #expect(grafted.size(of: a) == 150)
    #expect(grafted.size(of: grafted.root) == 190)
    #expect(!grafted.flags(of: a).contains(.restricted))
    #expect(grafted.flags(of: a).contains(.directory))
    #expect(grafted.inode(of: a) == 2)
    #expect(grafted.children(of: a).map { grafted.name(of: $0) } == ["x", "y", "z"])
    let y = try #require(grafted.node(atPath: "/r/a/y"))
    #expect(grafted.size(of: y) == 50 && grafted.inode(of: y) == 11 && grafted.device(of: y) == 1)
    #expect(grafted.flags(of: y) == .cloneExtra)
    let z = try #require(grafted.node(atPath: "/r/a/z"))
    #expect(grafted.flags(of: z).contains(.restricted))
    #expect(grafted.fileCount(of: grafted.root) == 4)
    #expect(grafted.fileCount(of: a) == 2)
    // a is now the largest child of the root.
    #expect(grafted.children(of: grafted.root).map { grafted.name(of: $0) } == ["a", "b", "c"])
    #expect(grafted.rootPath == tree.rootPath && grafted.scanDate == tree.scanDate)
}

@Test func graftIgnoresUnknownAndUnrestricted() throws {
    let tree = baseTree()
    let grafted = tree.grafting([
        "/r/b": subtreeA(rootPath: "/r/b"),      // not restricted
        "/r/missing": subtreeA(rootPath: "/r/missing"),
        "/r/a": subtreeA(rootPath: "/elsewhere"),  // subtree for another folder
    ])
    #expect(grafted.count == tree.count)
    #expect(grafted.size(of: grafted.root) == 40)
    let a = try #require(grafted.node(atPath: "/r/a"))
    #expect(grafted.flags(of: a).contains(.restricted))
    #expect(grafted.children(of: a).isEmpty)
    let b = try #require(grafted.node(atPath: "/r/b"))
    #expect(grafted.children(of: b).map { grafted.name(of: $0) } == ["f"])
}

@Test func graftKeepsOtherNodesIdentical() throws {
    let tree = baseTree()
    let grafted = tree.grafting(["/r/a": subtreeA()])
    for path in ["/r/b", "/r/b/f", "/r/c"] {
        let old = try #require(tree.node(atPath: path))
        let new = try #require(grafted.node(atPath: path))
        #expect(grafted.size(of: new) == tree.size(of: old))
        #expect(grafted.inode(of: new) == tree.inode(of: old))
        #expect(grafted.device(of: new) == tree.device(of: old))
        #expect(grafted.flags(of: new) == tree.flags(of: old))
        #expect(grafted.fileCount(of: new) == tree.fileCount(of: old))
        #expect(grafted.path(of: new) == path)
    }
    #expect(grafted.inode(of: grafted.root) == 1 && grafted.device(of: grafted.root) == 1)
}

@Test func graftKeepsRestrictedWhenSubtreeRootUnreadable() throws {
    let tree = baseTree()
    let b = FileTreeBuilder(rootPath: "/r/a", rootInode: 2, rootDevice: 1)
    b.markRestricted(b.root)
    let grafted = tree.grafting(["/r/a": b.finish()])
    let a = try #require(grafted.node(atPath: "/r/a"))
    #expect(grafted.flags(of: a).contains(.restricted))
}
