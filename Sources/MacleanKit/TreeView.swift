import Foundation
import MacleanCore

/// A directory's visible children: the tree's own contiguous range when nothing under it is
/// hidden or reordered (no allocation), otherwise a cached, re-sorted list.
public enum ViewChildren: RandomAccessCollection, Sendable {
    case raw(NodeChildren)
    case reordered([NodeID])

    public var startIndex: Int { 0 }
    public var endIndex: Int {
        switch self {
        case .raw(let c): c.count
        case .reordered(let a): a.count
        }
    }
    public subscript(i: Int) -> NodeID {
        switch self {
        case .raw(let c): c[i]
        case .reordered(let a): a[i]
        }
    }
}

/// Overlay on an immutable `FileTree`: collected and removed nodes are hidden and every
/// ancestor's size shrinks accordingly. Value type; the chart and list read through it.
public struct TreeView: Sendable {
    public let tree: FileTree
    /// Incremented by every mutation that changes something.
    public private(set) var generation = 0
    /// In collect order. Never holds a descendant of another collected node.
    public private(set) var collected: [NodeID] = []
    public private(set) var removed: Set<NodeID> = []

    private var collectedSet: Set<NodeID> = []
    /// Size taken away from each strict ancestor of a hidden node (zero entries are dropped).
    private var deltas: [Int32: Int64] = [:]
    /// Visible children, sorted by effective size, for parents whose list differs from the tree's.
    private var reordered: [Int32: [NodeID]] = [:]

    public init(tree: FileTree) { self.tree = tree }

    /// Effective size: raw minus the hidden nodes beneath it. A hidden node itself reports raw.
    public func size(of id: NodeID) -> Int64 {
        let raw = tree.size(of: id)
        if collectedSet.contains(id) || removed.contains(id) { return raw }
        return raw + (deltas[id.index] ?? 0)
    }

    /// True when `id` or an ancestor is collected or removed.
    public func isHidden(_ id: NodeID) -> Bool {
        var current: NodeID? = id
        while let node = current {
            if collectedSet.contains(node) || removed.contains(node) { return true }
            current = tree.parent(of: node)
        }
        return false
    }

    /// Visible children, sorted by effective size descending; ties keep tree order.
    public func children(of id: NodeID) -> ViewChildren {
        if let list = reordered[id.index] { return .reordered(list) }
        return .raw(tree.children(of: id))
    }

    /// Sum of the raw sizes of the collected nodes.
    public var collectedSize: Int64 { collected.reduce(0) { $0 + tree.size(of: $1) } }

    /// Collects the given nodes. Skips the root, hidden nodes and duplicates, and nodes
    /// inside another node of the batch. Absorbs already-collected descendants (they
    /// reappear in the view as ordinary nodes under the new collected folder).
    /// Returns the nodes actually added.
    @discardableResult
    public mutating func collect(_ ids: [NodeID]) -> [NodeID] {
        var candidates = Set<NodeID>()
        for id in ids where id != tree.root && !isHidden(id) { candidates.insert(id) }
        guard !candidates.isEmpty else { return [] }

        var accepted: [NodeID] = []
        var seen = Set<NodeID>()
        for id in ids where candidates.contains(id) && seen.insert(id).inserted {
            var inside = false
            var up = tree.parent(of: id)
            while let a = up {
                if candidates.contains(a) { inside = true; break }
                up = tree.parent(of: a)
            }
            if !inside { accepted.append(id) }
        }
        guard !accepted.isEmpty else { return [] }
        let acceptedSet = Set(accepted)

        var touched = Set<Int32>()
        // Absorb collected descendants: give their size back to the ancestors first.
        var absorbed = Set<NodeID>()
        for c in collected {
            var up = tree.parent(of: c)
            while let a = up {
                if acceptedSet.contains(a) { absorbed.insert(c); break }
                up = tree.parent(of: a)
            }
        }
        if !absorbed.isEmpty {
            for c in absorbed { shift(from: c, by: effectiveSize(c), touched: &touched) }
            collected.removeAll { absorbed.contains($0) }
            collectedSet.subtract(absorbed)
        }

        for id in accepted {
            shift(from: id, by: -effectiveSize(id), touched: &touched)
            collected.append(id)
            collectedSet.insert(id)
            touched.insert(tree.parent(of: id)!.index)
        }
        refresh(touched)
        generation += 1
        return accepted
    }

    /// Puts collected nodes back. Ids that are not collected are ignored.
    public mutating func uncollect(_ ids: [NodeID]) {
        let drop = Set(ids).intersection(collectedSet)
        guard !drop.isEmpty else { return }
        var touched = Set<Int32>()
        for id in drop {
            shift(from: id, by: effectiveSize(id), touched: &touched)
            if let p = tree.parent(of: id) { touched.insert(p.index) }
        }
        collected.removeAll { drop.contains($0) }
        collectedSet.subtract(drop)
        refresh(touched)
        generation += 1
    }

    public mutating func uncollectAll() { uncollect(collected) }

    /// Moves collected nodes to `removed`; their sizes stay subtracted. Ids that are not
    /// collected are ignored.
    public mutating func markRemoved(_ ids: [NodeID]) {
        let move = Set(ids).intersection(collectedSet)
        guard !move.isEmpty else { return }
        collected.removeAll { move.contains($0) }
        collectedSet.subtract(move)
        removed.formUnion(move)
        generation += 1
    }

    // MARK: - Internals

    /// Size a node contributes to its ancestors: raw minus hidden nodes already beneath it.
    private func effectiveSize(_ id: NodeID) -> Int64 { tree.size(of: id) + (deltas[id.index] ?? 0) }

    /// Adds `amount` to every strict ancestor's delta, recording them as touched.
    private mutating func shift(from id: NodeID, by amount: Int64, touched: inout Set<Int32>) {
        var up = tree.parent(of: id)
        while let a = up {
            let value = (deltas[a.index] ?? 0) + amount
            if value == 0 { deltas[a.index] = nil } else { deltas[a.index] = value }
            touched.insert(a.index)
            up = tree.parent(of: a)
        }
    }

    /// Rebuilds the visible, sorted child list of each touched parent, once.
    private mutating func refresh(_ parents: Set<Int32>) {
        for p in parents {
            let id = NodeID(index: p)
            let kids = tree.children(of: id)
            var visible: [(id: NodeID, size: Int64)] = []
            visible.reserveCapacity(kids.count)
            var changed = false
            for kid in kids {
                if collectedSet.contains(kid) || removed.contains(kid) { changed = true; continue }
                let size = tree.size(of: kid) + (deltas[kid.index] ?? 0)
                if size != tree.size(of: kid) { changed = true }
                visible.append((kid, size))
            }
            guard changed else { reordered[p] = nil; continue }
            // Stable by construction: equal sizes fall back to tree order (NodeID order).
            visible.sort { $0.size != $1.size ? $0.size > $1.size : $0.id < $1.id }
            reordered[p] = visible.map(\.id)
        }
    }
}
