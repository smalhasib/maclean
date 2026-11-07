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
}

/// Immutable, compact (struct-of-arrays) tree of a scanned directory.
/// Nodes are numbered in BFS order, so each node's children are the contiguous,
/// already-sorted range `firstChild ..< firstChild + childCount`.
public final class FileTree: Sendable {
    public let rootPath: String
    public let scanDate: Date

    let parents: [Int32]
    let firstChild: [Int32]
    let childCount: [Int32]
    let sizes: [Int64]
    let fileCounts: [Int64]
    let flagBits: [UInt16]
    let inodes: [UInt64]
    let devices: [Int32]
    let nameOffset: [UInt32]
    let nameLength: [UInt16]
    let names: [UInt8]

    init(rootPath: String, scanDate: Date, parents: [Int32], firstChild: [Int32],
         childCount: [Int32], sizes: [Int64], fileCounts: [Int64], flagBits: [UInt16],
         inodes: [UInt64], devices: [Int32], nameOffset: [UInt32], nameLength: [UInt16],
         names: [UInt8]) {
        self.rootPath = rootPath
        self.scanDate = scanDate
        self.parents = parents
        self.firstChild = firstChild
        self.childCount = childCount
        self.sizes = sizes
        self.fileCounts = fileCounts
        self.flagBits = flagBits
        self.inodes = inodes
        self.devices = devices
        self.nameOffset = nameOffset
        self.nameLength = nameLength
        self.names = names
    }

    public var root: NodeID { NodeID(index: 0) }
    public var count: Int { sizes.count }

    public func name(of id: NodeID) -> String {
        let i = Int(id.index)
        let start = Int(nameOffset[i])
        return String(decoding: names[start ..< start + Int(nameLength[i])], as: UTF8.self)
    }

    public func path(of id: NodeID) -> String {
        var components: [String] = []
        var current = id
        while let up = parent(of: current) {
            components.append(name(of: current))
            current = up
        }
        guard !components.isEmpty else { return rootPath }
        return rootPath + "/" + components.reversed().joined(separator: "/")
    }

    public func size(of id: NodeID) -> Int64 { sizes[Int(id.index)] }
    public func flags(of id: NodeID) -> NodeFlags { NodeFlags(rawValue: flagBits[Int(id.index)]) }
    public func inode(of id: NodeID) -> UInt64 { inodes[Int(id.index)] }
    public func device(of id: NodeID) -> Int32 { devices[Int(id.index)] }
    public func fileCount(of id: NodeID) -> Int64 { fileCounts[Int(id.index)] }

    public func parent(of id: NodeID) -> NodeID? {
        let p = parents[Int(id.index)]
        return p < 0 ? nil : NodeID(index: p)
    }

    public func children(of id: NodeID) -> [NodeID] {
        let i = Int(id.index)
        let first = firstChild[i]
        return (first ..< first + childCount[i]).map { NodeID(index: $0) }
    }
}
