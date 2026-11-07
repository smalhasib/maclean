import Darwin
import Foundation

/// Mutable, single-threaded staging area for a `FileTree`. Parents must be added before
/// their children. `finish()` produces the immutable, compact tree.
///
/// Memory: the staging columns and `finish()`'s scratch arrays live in anonymous mappings
/// (`MappedBuffer`), not the malloc heap. On macOS, freed large malloc blocks stay resident,
/// so growing-by-doubling Swift arrays leave ~1x of garbage behind and a freed column never
/// shrinks the footprint; an unmapped chunk is returned to the OS immediately.
public final class FileTreeBuilder {
    private let rootPath: String
    private let scanDate: Date
    private var parents: ChunkedColumn<Int32>
    private var sizes: ChunkedColumn<Int64>
    private var flagBits: ChunkedColumn<UInt16>
    private var inodes: ChunkedColumn<UInt64>
    private var devices: ChunkedColumn<Int32>
    /// Start of each node's name in `names` (append order); the next node's offset, or
    /// `names.count` for the last node, ends it.
    private var nameOffset: ChunkedColumn<UInt32>
    private var names: ChunkedColumn<UInt8>
    private var finished = false

    public convenience init(rootPath: String, rootInode: UInt64, rootDevice: Int32,
                            scanDate: Date = .now) {
        self.init(rootPath: rootPath, rootInode: rootInode, rootDevice: rootDevice,
                  scanDate: scanDate, chunkShift: 20)
    }

    /// `chunkShift`: log2 of the staging chunk size in elements (small values let tests
    /// cross chunk boundaries with few nodes).
    init(rootPath: String, rootInode: UInt64, rootDevice: Int32, scanDate: Date = .now,
         chunkShift: Int) {
        self.rootPath = rootPath
        self.scanDate = scanDate
        parents = ChunkedColumn(shift: chunkShift)
        sizes = ChunkedColumn(shift: chunkShift)
        flagBits = ChunkedColumn(shift: chunkShift)
        inodes = ChunkedColumn(shift: chunkShift)
        devices = ChunkedColumn(shift: chunkShift)
        nameOffset = ChunkedColumn(shift: chunkShift)
        names = ChunkedColumn(shift: chunkShift)
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
        precondition(id.index >= 0 && Int(id.index) < flagBits.count, "unknown node")
        flagBits[Int(id.index)] |= NodeFlags.restricted.rawValue
    }

    /// Builds the immutable tree. Call once: the builder's columns are consumed.
    ///
    /// Never holds a second copy of every column. Sizes are summed in place; the BFS
    /// `order` is computed from one shared child-list buffer (freed once `order` exists);
    /// then each column is permuted into an exactly-sized BFS-order array and its staging
    /// copy unmapped before the next one. Names go first, while only `counts` (4 B/node)
    /// stands in for the parent/child columns; those are derived from it afterwards.
    /// Peak ≈ 38 B/node + 2 × name bytes (the names copy), plus scanner state.
    public func finish() -> FileTree {
        precondition(!finished, "finish() may only be called once")
        finished = true
        // Move the columns into locals: no class-property access in the hot loops, and
        // reassigning a local unmaps its chunks.
        var parents = self.parents.take(), sizes = self.sizes.take()
        var flagBits = self.flagBits.take(), inodes = self.inodes.take()
        var devices = self.devices.take(), nameOffset = self.nameOffset.take()
        var names = self.names.take()
        let n = sizes.count
        nameOffset.append(UInt32(names.count))  // sentinel: name i is offset[i] ..< offset[i + 1]

        // 1. Bottom-up sums, in place: parents precede children in append order.
        for i in stride(from: n - 1, to: 0, by: -1) { sizes[Int(parents[i])] += sizes[i] }

        // 2. Group children by parent into one shared buffer: old node p's children are
        //    grouped[counts[p] ..< counts[p + 1]].
        var countsBuffer: MappedBuffer<Int32>? = MappedBuffer<Int32>(capacity: n + 1)  // zero-filled
        var groupedBuffer: MappedBuffer<Int32>? = MappedBuffer<Int32>(capacity: n - 1)
        let counts = countsBuffer!.base, grouped = groupedBuffer!.base
        for i in 1 ..< n { counts[Int(parents[i]) + 1] += 1 }
        for i in 0 ..< n { counts[i + 1] += counts[i] }
        for i in 1 ..< n {  // counts[p] doubles as p's fill cursor, shifted back below
            let p = Int(parents[i])
            grouped[Int(counts[p])] = Int32(i)
            counts[p] += 1
        }
        for i in stride(from: n, to: 0, by: -1) { counts[i] = counts[i - 1] }
        counts[0] = 0
        parents.removeAll()  // rebuilt from counts and order below

        // 3. Sort each child slice in place: size descending, then name bytes ascending.
        for p in 0 ..< n {
            let start = Int(counts[p]), end = Int(counts[p + 1])
            guard end - start > 1 else { continue }
            var kids = UnsafeMutableBufferPointer(start: grouped + start, count: end - start)
            kids.sort { a, b in
                let (ia, ib) = (Int(a), Int(b))
                let (sa, sb) = (sizes[ia], sizes[ib])
                if sa != sb { return sa > sb }
                return Self.namePrecedes(ia, ib, offsets: nameOffset, bytes: names)
            }
        }

        // 4. BFS order (order[new] = old): each node's sorted children follow in turn.
        var orderBuffer: MappedBuffer<Int32>? = MappedBuffer<Int32>(capacity: n)
        let order = orderBuffer!.base
        order[0] = 0
        var tail = 1
        for head in 0 ..< n {
            let old = Int(order[head])
            for j in Int(counts[old]) ..< Int(counts[old + 1]) {
                order[tail] = grouped[j]
                tail += 1
            }
        }
        groupedBuffer = nil

        // 5. Names (the largest copy) first, while the other staging columns are smallest.
        let newOffset = [UInt32](unsafeUninitializedCapacity: n + 1) { off, initialized in
            var pos: UInt32 = 0
            for k in 0 ..< n {
                let old = Int(order[k])
                off[k] = pos
                pos += nameOffset[old + 1] - nameOffset[old]
            }
            off[n] = pos
            initialized = n + 1
        }
        let newNames = [UInt8](unsafeUninitializedCapacity: names.count) { out, initialized in
            for k in 0 ..< n {
                let old = Int(order[k])
                let start = Int(nameOffset[old]), end = Int(nameOffset[old + 1])
                if end > start { names.copy(start ..< end, to: out.baseAddress! + Int(newOffset[k])) }
            }
            initialized = names.count
        }
        nameOffset.removeAll()
        names.removeAll()

        // 6. Parent/child columns from counts: children of new node k are contiguous.
        var newParents = [Int32](repeating: -1, count: n)
        var newFirstChild = [Int32](repeating: 0, count: n)
        var newChildCount = [Int32](repeating: 0, count: n)
        newParents.withUnsafeMutableBufferPointer { parent in
            var next: Int32 = 1
            for k in 0 ..< n {
                let old = Int(order[k])
                let kids = counts[old + 1] - counts[old]
                newFirstChild[k] = next
                newChildCount[k] = kids
                for c in Int(next) ..< Int(next + kids) { parent[c] = Int32(k) }
                next += kids
            }
        }
        countsBuffer = nil

        // 7. Remaining columns, one at a time.
        let newSizes = sizes.permuted(by: order, count: n); sizes.removeAll()
        let newFlags = flagBits.permuted(by: order, count: n); flagBits.removeAll()
        let newInodes = inodes.permuted(by: order, count: n); inodes.removeAll()
        let newDevices = devices.permuted(by: order, count: n); devices.removeAll()
        orderBuffer = nil

        return FileTree(
            rootPath: rootPath, scanDate: scanDate,
            parents: newParents, firstChild: newFirstChild, childCount: newChildCount,
            sizes: newSizes, flagBits: newFlags, inodes: newInodes, devices: newDevices,
            nameOffset: newOffset, names: newNames)
    }

    /// Byte-wise lexicographic order of two staged names (append-order node indices).
    private static func namePrecedes(_ a: Int, _ b: Int, offsets: ChunkedColumn<UInt32>,
                                     bytes: ChunkedColumn<UInt8>) -> Bool {
        var i = Int(offsets[a]), j = Int(offsets[b])
        let endA = Int(offsets[a + 1]), endB = Int(offsets[b + 1])
        while i < endA, j < endB {
            let (x, y) = (bytes[i], bytes[j])
            if x != y { return x < y }
            i += 1
            j += 1
        }
        return i == endA && j < endB
    }

    @discardableResult
    private func append(parent: Int32, name: String, size: Int64, flags: NodeFlags,
                        inode: UInt64, device: Int32) -> NodeID {
        precondition(!finished, "builder already finished")
        precondition(names.count + name.utf8.count <= Int(UInt32.max), "names exceed 4 GiB")
        parents.append(parent)
        sizes.append(size)
        flagBits.append(flags.rawValue)
        inodes.append(inode)
        devices.append(device)
        nameOffset.append(UInt32(names.count))
        for byte in name.utf8 { names.append(byte) }
        return NodeID(index: Int32(sizes.count - 1))
    }
}

// MARK: - Unmappable storage

/// Fixed-capacity, zero-filled buffer of trivial values in its own anonymous mapping,
/// unmapped (returned to the OS) on deinit. Pages are only resident once touched.
final class MappedBuffer<T: BitwiseCopyable> {
    let base: UnsafeMutablePointer<T>
    private let byteCount: Int

    init(capacity: Int) {
        precondition(capacity >= 0)
        byteCount = max(capacity * MemoryLayout<T>.stride, 1)
        let raw = mmap(nil, byteCount, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
        precondition(raw != MAP_FAILED, "out of memory")
        base = raw!.bindMemory(to: T.self, capacity: capacity)
    }

    deinit { munmap(base, byteCount) }
}

/// Append-only column stored in fixed-size mapped chunks: no growth copies, no garbage.
struct ChunkedColumn<T: BitwiseCopyable> {
    private let shift: Int
    private let mask: Int
    private var chunks: [MappedBuffer<T>] = []
    /// `chunks[i].base`, cached so element access never touches the class instances.
    private var bases: [UnsafeMutablePointer<T>] = []
    private(set) var count = 0

    /// Chunks hold `1 << shift` elements.
    init(shift: Int) {
        precondition((0 ..< 31).contains(shift))
        self.shift = shift
        mask = (1 << shift) - 1
    }

    mutating func append(_ value: T) {
        if count & mask == 0 {
            chunks.append(MappedBuffer(capacity: 1 << shift))
            bases.append(chunks[chunks.count - 1].base)
        }
        bases[count >> shift][count & mask] = value
        count += 1
    }

    /// Unchecked beyond the chunk lookup: callers pass indices below `count`.
    subscript(i: Int) -> T {
        get { bases[i >> shift][i & mask] }
        nonmutating set { bases[i >> shift][i & mask] = newValue }
    }

    /// Unmaps every chunk.
    mutating func removeAll() {
        bases = []
        chunks = []
        count = 0
    }

    /// Returns the column, leaving `self` empty.
    mutating func take() -> ChunkedColumn {
        defer { removeAll() }
        return self
    }

    /// Copies elements `range` (which may span chunks) to `dest`.
    func copy(_ range: Range<Int>, to dest: UnsafeMutablePointer<T>) {
        var i = range.lowerBound, out = dest
        while i < range.upperBound {
            let within = i & mask
            let run = min(range.upperBound - i, (1 << shift) - within)
            out.initialize(from: bases[i >> shift] + within, count: run)
            i += run
            out += run
        }
    }

    /// An exactly-sized array whose element `k` is `self[order[k]]`, for `k < count`.
    func permuted(by order: UnsafeMutablePointer<Int32>, count: Int) -> [T] {
        [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            for k in 0 ..< count { (buffer.baseAddress! + k).initialize(to: self[Int(order[k])]) }
            initialized = count
        }
    }
}
