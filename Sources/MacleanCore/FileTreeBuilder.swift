import Foundation

/// Mutable, single-threaded staging area for a `FileTree`. Parents must be added before
/// their children. `finish()` produces the immutable, compact tree.
public final class FileTreeBuilder {
    private let rootPath: String
    private let scanDate: Date
    private var parents: [Int32] = []
    private var sizes: [Int64] = []
    private var flagBits: [UInt16] = []
    private var inodes: [UInt64] = []
    private var devices: [Int32] = []
    private var nameOffset: [UInt32] = []
    private var nameLength: [UInt16] = []
    private var names: [UInt8] = []

    public init(rootPath: String, rootInode: UInt64, rootDevice: Int32, scanDate: Date = .now) {
        self.rootPath = rootPath
        self.scanDate = scanDate
        append(parent: -1, name: "", size: 0, flags: .directory, inode: rootInode, device: rootDevice)
    }

    public var root: NodeID { NodeID(index: 0) }

    @discardableResult
    public func add(parent: NodeID, name: String, size: Int64, flags: NodeFlags,
                    inode: UInt64, device: Int32) -> NodeID {
        precondition(Int(parent.index) < sizes.count, "parent must be added before its children")
        return append(parent: parent.index, name: name, size: size, flags: flags,
                      inode: inode, device: device)
    }

    public func markRestricted(_ id: NodeID) {
        flagBits[Int(id.index)] |= NodeFlags.restricted.rawValue
    }

    public func finish() -> FileTree {
        let n = sizes.count

        // Bottom-up sums: parents precede children in append order.
        var total = sizes
        var files = flagBits.map { $0 & NodeFlags.directory.rawValue == 0 ? Int64(1) : 0 }
        for i in stride(from: n - 1, to: 0, by: -1) {
            let p = Int(parents[i])
            total[p] += total[i]
            files[p] += files[i]
        }

        // Group children by parent (append order within a parent).
        var counts = [Int32](repeating: 0, count: n + 1)
        for i in 1 ..< n { counts[Int(parents[i]) + 1] += 1 }
        for i in 0 ..< n { counts[i + 1] += counts[i] }
        var cursor = counts
        var grouped = [Int32](repeating: 0, count: max(n - 1, 0))
        for i in 1 ..< n {
            let p = Int(parents[i])
            grouped[Int(cursor[p])] = Int32(i)
            cursor[p] += 1
        }

        // BFS renumbering; each node's sorted children get a contiguous new range.
        var order: [Int32] = [0]
        order.reserveCapacity(n)
        var newFirstChild = [Int32](repeating: 0, count: n)
        var newChildCount = [Int32](repeating: 0, count: n)
        var head = 0
        while head < order.count {
            let old = Int(order[head])
            var kids = Array(grouped[Int(counts[old]) ..< Int(counts[old + 1])])
            names.withUnsafeBufferPointer { bytes in
                kids.sort { a, b in
                    let (ia, ib) = (Int(a), Int(b))
                    if total[ia] != total[ib] { return total[ia] > total[ib] }
                    let na = bytes[Int(nameOffset[ia]) ..< Int(nameOffset[ia]) + Int(nameLength[ia])]
                    let nb = bytes[Int(nameOffset[ib]) ..< Int(nameOffset[ib]) + Int(nameLength[ib])]
                    return na.lexicographicallyPrecedes(nb)
                }
            }
            newFirstChild[head] = Int32(order.count)
            newChildCount[head] = Int32(kids.count)
            order.append(contentsOf: kids)
            head += 1
        }

        var newIndex = [Int32](repeating: 0, count: n)
        for (new, old) in order.enumerated() { newIndex[Int(old)] = Int32(new) }

        let o = order.map(Int.init)
        return FileTree(
            rootPath: rootPath,
            scanDate: scanDate,
            parents: o.map { $0 == 0 ? -1 : newIndex[Int(parents[$0])] },
            firstChild: newFirstChild,
            childCount: newChildCount,
            sizes: o.map { total[$0] },
            fileCounts: o.map { files[$0] },
            flagBits: o.map { flagBits[$0] },
            inodes: o.map { inodes[$0] },
            devices: o.map { devices[$0] },
            nameOffset: o.map { nameOffset[$0] },
            nameLength: o.map { nameLength[$0] },
            names: names)
    }

    @discardableResult
    private func append(parent: Int32, name: String, size: Int64, flags: NodeFlags,
                        inode: UInt64, device: Int32) -> NodeID {
        let bytes = Array(name.utf8)
        precondition(bytes.count <= Int(UInt16.max), "file name too long")
        parents.append(parent)
        sizes.append(size)
        flagBits.append(flags.rawValue)
        inodes.append(inode)
        devices.append(device)
        nameOffset.append(UInt32(names.count))
        nameLength.append(UInt16(bytes.count))
        names.append(contentsOf: bytes)
        return NodeID(index: Int32(sizes.count - 1))
    }
}
