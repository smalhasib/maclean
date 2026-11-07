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

@Suite(.serialized) struct SunburstLayoutTests {
    @Test func anglesAreProportional() {
        let b = builder()
        add(b, b.root, "a", 300)
        add(b, b.root, "b", 100)
        let t = b.finish()
        let l = SunburstLayout(tree: t, root: t.root)
        #expect(l.segments.count == 2)
        #expect(l.segments[0].startAngle == 0)
        #expect(abs(l.segments[0].endAngle - 3 * .pi / 2) < 1e-9)
        #expect(abs(l.segments[1].startAngle - 3 * .pi / 2) < 1e-9)
        #expect(abs(l.segments[1].endAngle - 2 * .pi) < 1e-9)
        #expect(l.segments.map { $0.topLevelIndex } == [0, 1])
        #expect(l.segments.allSatisfy { $0.ring == 1 && $0.kind == .file && $0.parent == t.root })
    }

    @Test func tinyTailIsMerged() {
        let b = builder()
        let f1 = add(b, b.root, "f1", 0, .directory)
        add(b, f1, "x", 1000)
        let f2 = add(b, b.root, "f2", 0, .directory)
        add(b, f2, "y", 1000)
        for i in 0..<3 { add(b, b.root, "s\(i)", 1) }
        let t = b.finish()
        let l = SunburstLayout(tree: t, root: t.root)
        let ring1 = l.segments.filter { $0.ring == 1 }
        #expect(ring1.filter { $0.kind == .folder }.count == 2)
        let merged = ring1.filter { $0.kind == .smallerObjects }
        #expect(merged.count == 1)
        #expect(merged[0].mergedSize == 3)
        #expect(merged[0].node == nil)
        #expect(merged[0].parent == t.root)
        #expect(merged[0].topLevelIndex == 2)
        #expect(abs(merged[0].endAngle - 2 * .pi) < 1e-9)
    }

    @Test func hugeFolderStaysBounded() {
        let b = builder()
        let d = add(b, b.root, "huge", 0, .directory)
        for i in 0..<100_000 { add(b, d, "f\(i)", 1) }
        add(b, d, "big", 10_000_000)
        let t = b.finish()
        let l = SunburstLayout(tree: t, root: t.root)
        #expect(l.segments.count < 2_000)
        #expect(l.segments.contains { $0.kind == .smallerObjects && $0.ring == 2 })
    }

    @Test func stopsAtPackagesRestrictedAndMounts() {
        let b = builder()
        let p = add(b, b.root, "p", 0, [.directory, .package])
        add(b, p, "inP", 50)
        let r = add(b, b.root, "r", 0, [.directory, .restricted])
        add(b, r, "inR", 50)
        let m = add(b, b.root, "m", 0, [.directory, .mountPoint])
        add(b, m, "inM", 50)
        let t = b.finish()
        let l = SunburstLayout(tree: t, root: t.root)
        #expect(l.segments.allSatisfy { $0.ring == 1 })
        #expect(Set(l.segments.map { $0.kind }) == [.package, .restricted, .mountPoint])
    }

    @Test func emptyTreeIsEmpty() {
        let b = builder()
        add(b, b.root, "z1", 0)
        add(b, b.root, "z2", 0)
        let t = b.finish()
        let l = SunburstLayout(tree: t, root: t.root)
        #expect(l.isEmpty)
        #expect(l.segments.allSatisfy { !$0.startAngle.isNaN && !$0.endAngle.isNaN })
    }

    @Test func ringsAreCapped() {
        let b = builder()
        var parent = b.root
        for i in 0..<7 { parent = add(b, parent, "d\(i)", 0, .directory) }
        add(b, parent, "leaf", 10)
        let t = b.finish()
        let l = SunburstLayout(tree: t, root: t.root)
        #expect(l.segments.map { $0.ring }.max() == 5)
        #expect(l.segments.count == 5)
    }

    @Test func hitTestFindsSegment() {
        let b = builder()
        let a = add(b, b.root, "a", 0, .directory)
        add(b, a, "a1", 200)
        add(b, a, "a2", 100)
        add(b, b.root, "b", 100)
        let t = b.finish()
        let l = SunburstLayout(tree: t, root: t.root)
        let hit = l.segment(atRadius: 100 + 1.5 * 40, angle: .pi / 2, innerRadius: 100, ringWidth: 40)
        #expect(hit?.node.map { t.name(of: $0) } == "a1")
        #expect(hit?.ring == 2)
        let ring1 = l.segment(atRadius: 110, angle: 5.5, innerRadius: 100, ringWidth: 40)
        #expect(ring1?.ring == 1)
        #expect(ring1?.topLevelIndex == 1)
        #expect(l.segment(atRadius: 50, angle: 1, innerRadius: 100, ringWidth: 40) == nil)
        #expect(l.segment(atRadius: 100 + 5 * 40 + 1, angle: 1, innerRadius: 100, ringWidth: 40) == nil)
        // angle outside [0, 2π) wraps
        #expect(l.segment(atRadius: 110, angle: -0.1, innerRadius: 100, ringWidth: 40)?.node != nil)
        // ring 2 has no segment where "b" (a file) would be
        #expect(l.segment(atRadius: 100 + 1.5 * 40, angle: 5.5, innerRadius: 100, ringWidth: 40) == nil)
        // The index form points at the same segment.
        let i = l.segmentIndex(atRadius: 100 + 1.5 * 40, angle: .pi / 2, innerRadius: 100, ringWidth: 40)
        #expect(i.map { l.segments[$0] } == hit)
        #expect(l.segmentIndex(atRadius: 50, angle: 1, innerRadius: 100, ringWidth: 40) == nil)
    }

    @Test func nonPositiveRingsGiveEmptyLayout() {
        let b = builder()
        add(b, b.root, "a", 10)
        let t = b.finish()
        for rings in [0, -3] {
            let l = SunburstLayout(tree: t, root: t.root, rings: rings)
            #expect(l.segments.isEmpty)
            #expect(l.isEmpty)
            #expect(l.segment(atRadius: 110, angle: 1, innerRadius: 100, ringWidth: 40) == nil)
        }
    }

    @Test func hitTestIsHardened() {
        let b = builder()
        add(b, b.root, "a", 300)
        add(b, b.root, "b", 100)
        let t = b.finish()
        let l = SunburstLayout(tree: t, root: t.root)
        #expect(l.segment(atRadius: 1e300, angle: 1, innerRadius: 100, ringWidth: 40) == nil)
        #expect(l.segment(atRadius: 1e300, angle: 1, innerRadius: 100, ringWidth: 1e-300) == nil)
        for angle in [2 * Double.pi, -1e-20, 0] {
            let hit = l.segment(atRadius: 110, angle: angle, innerRadius: 100, ringWidth: 40)
            #expect(hit?.startAngle == 0)
        }
    }

    @Test func layoutIsFast() {
        let b = builder()
        for i in 0..<100 {
            let d = add(b, b.root, "d\(i)", 0, .directory)
            for j in 0..<9999 { add(b, d, "f\(j)", Int64(1 + (i * 31 + j * 17) % 5000)) }
        }
        let t = b.finish()
        let clock = ContinuousClock()
        var l: SunburstLayout?
        let elapsed = clock.measure { l = SunburstLayout(tree: t, root: t.root) }
        print("layoutIsFast: \(elapsed) for \(t.count) nodes, \(l?.segments.count ?? 0) segments")
        #expect(elapsed < .milliseconds(200))
    }
}
