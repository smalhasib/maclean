import Foundation

public struct NodeID: Hashable, Sendable, Comparable {
    public let index: Int32

    public init(index: Int32) { self.index = index }

    public static func < (lhs: NodeID, rhs: NodeID) -> Bool { lhs.index < rhs.index }
}

public struct NodeFlags: OptionSet, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let directory = NodeFlags(rawValue: 1 << 0)
    public static let symlink = NodeFlags(rawValue: 1 << 1)
    public static let package = NodeFlags(rawValue: 1 << 2)
    public static let restricted = NodeFlags(rawValue: 1 << 3)
    public static let hardLinkFirst = NodeFlags(rawValue: 1 << 4)
    public static let hardLinkExtra = NodeFlags(rawValue: 1 << 5)
    public static let cloneExtra = NodeFlags(rawValue: 1 << 6)
    /// A directory that is a mount point (a volume root); recorded empty, never descended.
    public static let mountPoint = NodeFlags(rawValue: 1 << 7)
}

/// Immutable, compact (struct-of-arrays) tree of a scanned directory.
/// Nodes are numbered in BFS order, so each node's children are the contiguous,
/// already-sorted range `firstChild ..< firstChild + childCount`.
///
/// Storage is 38 B/node plus name bytes: `nameOffset` has a sentinel at index `count`, so
/// node `i`'s name is `names[nameOffset[i] ..< nameOffset[i + 1]]` (names are in BFS order).
public final class FileTree: Sendable {
    public let rootPath: String
    public let scanDate: Date

    let parents: [Int32]
    let firstChild: [Int32]
    let childCount: [Int32]
    let sizes: [Int64]
    let flagBits: [UInt16]
    let inodes: [UInt64]
    let devices: [Int32]
    let nameOffset: [UInt32]
    let names: [UInt8]

    init(rootPath: String, scanDate: Date, parents: [Int32], firstChild: [Int32],
         childCount: [Int32], sizes: [Int64], flagBits: [UInt16], inodes: [UInt64],
         devices: [Int32], nameOffset: [UInt32], names: [UInt8]) {
        self.rootPath = rootPath
        self.scanDate = scanDate
        self.parents = parents
        self.firstChild = firstChild
        self.childCount = childCount
        self.sizes = sizes
        self.flagBits = flagBits
        self.inodes = inodes
        self.devices = devices
        self.nameOffset = nameOffset
        self.names = names
    }

    public var root: NodeID { NodeID(index: 0) }
    public var count: Int { sizes.count }

    /// Bytes held by the node columns and the names (element counts, not capacities).
    var storageBytes: Int {
        func bytes<T>(_ a: [T]) -> Int { a.count * MemoryLayout<T>.stride }
        return bytes(parents) + bytes(firstChild) + bytes(childCount) + bytes(sizes)
            + bytes(flagBits) + bytes(inodes) + bytes(devices) + bytes(nameOffset) + bytes(names)
    }

    public func name(of id: NodeID) -> String {
        let i = Int(id.index)
        return String(decoding: names[Int(nameOffset[i]) ..< Int(nameOffset[i + 1])], as: UTF8.self)
    }

    public func path(of id: NodeID) -> String {
        var components: [String] = []
        var current = id
        while let up = parent(of: current) {
            components.append(name(of: current))
            current = up
        }
        guard !components.isEmpty else { return rootPath }
        let base = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        return base + "/" + components.reversed().joined(separator: "/")
    }

    /// Allocated bytes of the node. Invariant: a directory's size equals the sum
    /// of its children's sizes (`SunburstLayout`'s tail math relies on it).
    public func size(of id: NodeID) -> Int64 { sizes[Int(id.index)] }
    public func flags(of id: NodeID) -> NodeFlags { NodeFlags(rawValue: flagBits[Int(id.index)]) }
    public func inode(of id: NodeID) -> UInt64 { inodes[Int(id.index)] }
    public func device(of id: NodeID) -> Int32 { devices[Int(id.index)] }

    /// Number of non-directory nodes in the subtree rooted at `id` (1 for a file itself).
    /// Not stored: computed by walking the subtree, so it is O(subtree size).
    public func fileCount(of id: NodeID) -> Int64 {
        let dir = NodeFlags.directory.rawValue
        if id == root {
            // The whole tree: a linear scan, no stack needed.
            return flagBits.reduce(into: Int64(0)) { $0 += $1 & dir == 0 ? 1 : 0 }
        }
        var files: Int64 = 0
        var stack: [Int32] = [id.index]
        while let i = stack.popLast().map(Int.init) {
            if flagBits[i] & dir == 0 { files += 1 }
            let first = firstChild[i]
            if childCount[i] > 0 { stack.append(contentsOf: first ..< first + childCount[i]) }
        }
        return files
    }

    /// The node at the absolute `path`, walking down from the root by name;
    /// nil when it is outside the tree or no longer there.
    public func node(atPath path: String) -> NodeID? {
        if path == rootPath { return root }
        guard PathUtil.isInside(path, orEqualTo: rootPath) else { return nil }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var node = root
        for component in path.dropFirst(prefix.count).split(separator: "/") {
            guard let next = children(of: node).first(where: { name(of: $0) == component }) else { return nil }
            node = next
        }
        return node
    }

    public func parent(of id: NodeID) -> NodeID? {
        let p = parents[Int(id.index)]
        return p < 0 ? nil : NodeID(index: p)
    }

    public func children(of id: NodeID) -> NodeChildren {
        let i = Int(id.index)
        return NodeChildren(first: Int(firstChild[i]), length: Int(childCount[i]))
    }

    /// File counts (non-directory nodes in each subtree) for every node, indexed by
    /// `NodeID.index`, in O(n): BFS numbering puts children after parents, so one
    /// reverse pass accumulates into parents. Agrees with `fileCount(of:)`.
    public func fileCounts() -> [Int64] {
        let dir = NodeFlags.directory.rawValue
        var counts = [Int64](repeating: 0, count: count)
        for i in stride(from: count - 1, through: 0, by: -1) {
            if flagBits[i] & dir == 0 { counts[i] += 1 }
            let p = parents[i]
            if p >= 0 { counts[Int(p)] += counts[i] }
        }
        return counts
    }
}

/// A node's children: the contiguous range of BFS-numbered ids, with no allocation.
public struct NodeChildren: RandomAccessCollection, Sendable, Equatable {
    let first: Int
    let length: Int

    public var startIndex: Int { 0 }
    public var endIndex: Int { length }
    public subscript(i: Int) -> NodeID {
        precondition(i >= 0 && i < length, "NodeChildren index out of range")
        return NodeID(index: Int32(first + i))
    }
}
