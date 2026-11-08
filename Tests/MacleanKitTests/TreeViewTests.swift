import Foundation
import Testing
import MacleanCore
@testable import MacleanKit

private func builder() -> FileTreeBuilder {
    FileTreeBuilder(rootPath: "/r", rootInode: 1, rootDevice: 1)
}

@discardableResult
private func add(_ b: FileTreeBuilder, _ parent: NodeID, _ name: String, _ size: Int64,
                 _ flags: NodeFlags = []) -> NodeID {
    b.add(parent: parent, name: name, size: size, flags: flags,
          inode: UInt64(abs(name.hashValue % 1_000_000)) + 2, device: 1)
}

/// /r/a/b/{f(100), g(50)}, /r/a/h(25), /r/c(10). Directory sizes are the sums of their children.
private func sample() -> FileTree {
    let b = builder()
    let a = add(b, b.root, "a", 0, .directory)
    let bb = add(b, a, "b", 0, .directory)
    add(b, bb, "f", 100)
    add(b, bb, "g", 50)
    add(b, a, "h", 25)
    add(b, b.root, "c", 10)
    return b.finish()
}

private func id(_ t: FileTree, _ path: String) -> NodeID { t.node(atPath: "/r/" + path)! }

private func allNodes(_ t: FileTree) -> [NodeID] { (0 ..< t.count).map { NodeID(index: Int32($0)) } }

@Suite struct TreeViewTests {
    @Test func collectShrinksEveryAncestor() {
        let t = sample()
        var v = TreeView(tree: t)
        let (f, bb, a) = (id(t, "a/b/f"), id(t, "a/b"), id(t, "a"))
        #expect(v.collect([f]) == [f])
        #expect(v.size(of: bb) == 50)
        #expect(v.size(of: a) == 75)
        #expect(v.size(of: t.root) == 85)
        #expect(v.isHidden(f))
        #expect(!v.children(of: bb).contains(f))
        #expect(v.collectedSize == 100)
        #expect(v.generation == 1)
    }

    @Test func uncollectRestoresExactly() {
        let t = sample()
        var v = TreeView(tree: t)
        v.collect([id(t, "a/b/f"), id(t, "c")])
        v.uncollect([id(t, "a/b/f"), id(t, "c")])
        for n in allNodes(t) {
            #expect(v.size(of: n) == t.size(of: n))
            #expect(Array(v.children(of: n)) == Array(t.children(of: n)))
        }
    }

    @Test func collectingParentAbsorbsChildren() {
        let t = sample()
        var v = TreeView(tree: t)
        let (f, bb) = (id(t, "a/b/f"), id(t, "a/b"))
        v.collect([f])
        #expect(v.collect([bb]) == [bb])
        #expect(v.collected == [bb])
        #expect(v.size(of: t.root) == 185 - 150)
        v.uncollect([bb])
        #expect(v.collected.isEmpty)
        #expect(!v.isHidden(f))
        #expect(v.size(of: t.root) == 185)
    }

    @Test func collectingFolderAndItsChildInOneBatchKeepsOnlyFolder() {
        let t = sample()
        var v = TreeView(tree: t)
        let (f, bb) = (id(t, "a/b/f"), id(t, "a/b"))
        #expect(v.collect([f, bb, bb]) == [bb])
        #expect(v.size(of: t.root) == 35)
    }

    @Test func collectSkipsRootAndHidden() {
        let t = sample()
        var v = TreeView(tree: t)
        #expect(v.collect([t.root]).isEmpty)
        #expect(v.generation == 0)
        v.collect([id(t, "a/b")])
        #expect(v.collect([id(t, "a/b/f")]).isEmpty)
    }

    @Test func childrenResortByEffectiveSize() {
        let b = builder()
        let x = add(b, b.root, "x", 0, .directory)
        add(b, x, "x1", 150)
        add(b, x, "x2", 150)
        let y = add(b, b.root, "y", 0, .directory)
        add(b, y, "y1", 200)
        let t = b.finish()
        var v = TreeView(tree: t)
        let (xn, yn) = (id(t, "x"), id(t, "y"))
        #expect(Array(v.children(of: t.root)) == [xn, yn])
        v.collect([id(t, "x/x1")])
        #expect(Array(v.children(of: t.root)) == [yn, xn])
        #expect(Array(v.children(of: xn)) == [id(t, "x/x2")])
    }

    @Test func removedStaysSubtracted() {
        let t = sample()
        var v = TreeView(tree: t)
        let (f, bb) = (id(t, "a/b/f"), id(t, "a/b"))
        v.collect([f])
        v.markRemoved([f])
        #expect(v.collected.isEmpty)
        #expect(v.removed == [f])
        #expect(v.size(of: bb) == 50)
        v.uncollectAll()
        #expect(v.size(of: bb) == 50)
        #expect(v.isHidden(f))
    }

    @Test func markDeletedHidesUncollectedAndCollectedNodes() {
        let t = sample()
        var v = TreeView(tree: t)
        let (f, g, h, bb, a) = (id(t, "a/b/f"), id(t, "a/b/g"), id(t, "a/h"), id(t, "a/b"), id(t, "a"))
        v.collect([h])
        v.markDeleted([f, h, t.root])
        #expect(v.removed == [f, h])
        #expect(v.collected.isEmpty)
        #expect(v.size(of: bb) == 50)
        #expect(v.size(of: a) == 50)
        // Already hidden: ignored.
        let generation = v.generation
        v.markDeleted([f])
        #expect(v.generation == generation)
        // A collected descendant of a deleted folder goes with it.
        v.collect([g])
        v.markDeleted([bb])
        #expect(v.collected.isEmpty)
        #expect(v.removed == [f, h, bb])
        #expect(v.size(of: a) == 0)
    }

    @Test func layoutTailMatchesEffectiveSizes() {
        let t = sample()
        var v = TreeView(tree: t)
        let f = id(t, "a/b/f")
        v.collect([f])
        let l = SunburstLayout(view: v, root: t.root, minAngle: 0.01)
        let ring1 = l.segments.filter { $0.ring == 1 }
        let span = ring1.reduce(0.0) { $0 + ($1.endAngle - $1.startAngle) }
        #expect(abs(span - 2 * .pi) < 1e-9)
        #expect(!l.segments.contains { $0.node == f })
    }

    @Test func batchCollectIsFast() {
        let b = builder()
        let d = add(b, b.root, "folder", 0, .directory)
        for i in 0..<10_000 { add(b, d, "f\(i)", 1) }
        let t = b.finish()
        var v = TreeView(tree: t)
        let folder = id(t, "folder")
        let kids = Array(t.children(of: folder))
        let clock = ContinuousClock()
        let elapsed = clock.measure { v.collect(kids) }
        #expect(elapsed < .milliseconds(100))
        #expect(v.size(of: folder) == 0)
        #expect(v.children(of: folder).isEmpty)
    }
}
