import Foundation
import MacleanCore

public enum SegmentKind: Sendable, Equatable { case folder, file, package, restricted, mountPoint, smallerObjects }

public struct Segment: Sendable, Equatable {
    /// nil for a merged `smallerObjects` segment.
    public let node: NodeID?
    /// The node whose children this ring slice belongs to.
    public let parent: NodeID
    /// 1 = innermost ring.
    public let ring: Int
    /// Radians, 0 = 12 o'clock, clockwise.
    public let startAngle: Double
    public let endAngle: Double
    /// Index of the ring-1 ancestor among the root's children (drives hue).
    public let topLevelIndex: Int
    public let kind: SegmentKind
    /// `smallerObjects`: combined size; otherwise the node's size.
    public let mergedSize: Int64
}

/// Ring layout of the visible part of a tree. Only the visible rings below `root` are
/// computed, and each folder's children are cut off by binary search (children are sorted
/// by size), so cost scales with the segments produced, not with folder size.
public struct SunburstLayout: Sendable {
    public static let maxRings = 5
    public static let minAngle = 0.6 * .pi / 180

    public let root: NodeID
    /// Ring 1 first, angular order within a ring.
    public let segments: [Segment]
    private let ringStarts: [Int]   // ringStarts[k] ..< ringStarts[k + 1] are ring k + 1's segments
    private let isEmptyLayout: Bool

    public var isEmpty: Bool { isEmptyLayout }

    public init(tree: FileTree, root: NodeID, rings: Int = maxRings, minAngle: Double = minAngle) {
        self.root = root
        let rootSize = tree.size(of: root)
        var out: [Segment] = []
        var starts: [Int] = [0]

        struct Open { let node: NodeID; let start: Double; let end: Double; let top: Int }
        var frontier = [Open(node: root, start: 0, end: 2 * .pi, top: 0)]

        for ring in 1 ..< max(rings, 0) + 1 {
            guard !frontier.isEmpty else { break }
            var next: [Open] = []
            for open in frontier {
                let parentSize = tree.size(of: open.node)
                guard parentSize > 0 else { continue }
                let kids = tree.children(of: open.node)
                guard !kids.isEmpty else { continue }
                let span = open.end - open.start
                let scale = span / Double(parentSize)

                // Sorted by size descending: the visible head is a prefix; find its end.
                var lo = 0, hi = kids.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    let size = tree.size(of: kids[mid])
                    if size > 0 && Double(size) * scale >= minAngle { lo = mid + 1 } else { hi = mid }
                }
                let visible = lo

                var cumulative: Int64 = 0
                for i in 0 ..< visible {
                    let id = kids[i]
                    let size = tree.size(of: id)
                    let a0 = open.start + Double(cumulative) * scale
                    cumulative += size
                    let a1 = open.start + Double(cumulative) * scale
                    let flags = tree.flags(of: id)
                    let kind: SegmentKind
                    if flags.contains(.directory) {
                        if flags.contains(.package) { kind = .package }
                        else if flags.contains(.restricted) { kind = .restricted }
                        else if flags.contains(.mountPoint) { kind = .mountPoint }
                        else { kind = .folder }
                    } else {
                        kind = .file
                    }
                    let top = ring == 1 ? i : open.top
                    out.append(Segment(node: id, parent: open.node, ring: ring, startAngle: a0,
                                       endAngle: a1, topLevelIndex: top, kind: kind, mergedSize: size))
                    if kind == .folder, ring < rings {
                        next.append(Open(node: id, start: a0, end: a1, top: top))
                    }
                }

                if visible < kids.count {
                    // A directory's size is the sum of its children's, so the tail is the remainder.
                    let tail = max(parentSize - cumulative, 0)
                    if tail > 0 {
                        let a0 = open.start + Double(cumulative) * scale
                        let a1 = open.start + Double(cumulative + tail) * scale
                        out.append(Segment(node: nil, parent: open.node, ring: ring, startAngle: a0,
                                           endAngle: a1, topLevelIndex: ring == 1 ? visible : open.top,
                                           kind: .smallerObjects, mergedSize: tail))
                    }
                }
            }
            starts.append(out.count)
            frontier = next
        }

        segments = out
        ringStarts = starts
        isEmptyLayout = rootSize <= 0 || out.isEmpty
    }

    public func segment(atRadius r: Double, angle: Double, innerRadius: Double, ringWidth: Double) -> Segment? {
        segmentIndex(atRadius: r, angle: angle, innerRadius: innerRadius, ringWidth: ringWidth).map { segments[$0] }
    }

    /// Index into `segments` of the segment at polar position (`r`, `angle`), if any.
    public func segmentIndex(atRadius r: Double, angle: Double, innerRadius: Double, ringWidth: Double) -> Int? {
        guard ringWidth > 0, r >= innerRadius, r.isFinite, angle.isFinite else { return nil }
        let ringsDrawn = Double(ringStarts.count - 1)
        let q = ((r - innerRadius) / ringWidth).rounded(.down)
        guard q.isFinite, q < ringsDrawn else { return nil }
        let ring = Int(q) + 1
        guard ring >= 1, ring < ringStarts.count else { return nil }
        let twoPi = 2 * Double.pi
        var a = angle.truncatingRemainder(dividingBy: twoPi)
        if a < 0 { a += twoPi }
        if a >= twoPi { a = 0 }

        // Last segment in the ring whose startAngle <= a.
        var lo = ringStarts[ring - 1], hi = ringStarts[ring]
        while lo < hi {
            let mid = (lo + hi) / 2
            if segments[mid].startAngle <= a { lo = mid + 1 } else { hi = mid }
        }
        guard lo > ringStarts[ring - 1] else { return nil }
        return a < segments[lo - 1].endAngle ? lo - 1 : nil
    }
}
