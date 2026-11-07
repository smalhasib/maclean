import Foundation

public enum ArchiveError: Error, Equatable {
    case badMagic
    case unsupportedVersion(UInt32)
    case truncated
}

/// Binary save/load format for `FileTree` (all integers little-endian).
///
/// Layout: magic "MCLN", version u32, node count u64, scanDate f64 bits (u64),
/// rootPath byte length u32 + UTF-8 bytes, then the raw arrays in `FileTree`
/// field order (parents, firstChild, childCount, sizes, fileCounts, flagBits,
/// inodes, devices, nameOffset, nameLength), then names byte count u64 + bytes.
public enum TreeArchive {
    static let magic: [UInt8] = Array("MCLN".utf8)
    static let version: UInt32 = 1

    public static func write(_ tree: FileTree, to url: URL) throws {
        var data = Data()
        data.append(contentsOf: magic)
        put(&data, version)
        put(&data, UInt64(tree.count))
        put(&data, tree.scanDate.timeIntervalSince1970.bitPattern)
        let root = Array(tree.rootPath.utf8)
        put(&data, UInt32(root.count))
        data.append(contentsOf: root)
        putArray(&data, tree.parents)
        putArray(&data, tree.firstChild)
        putArray(&data, tree.childCount)
        putArray(&data, tree.sizes)
        putArray(&data, tree.fileCounts)
        putArray(&data, tree.flagBits)
        putArray(&data, tree.inodes)
        putArray(&data, tree.devices)
        putArray(&data, tree.nameOffset)
        putArray(&data, tree.nameLength)
        put(&data, UInt64(tree.names.count))
        data.append(contentsOf: tree.names)

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: tmp)
            if rename(tmp.path, url.path) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    public static func read(from url: URL) throws -> FileTree {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var r = Reader(data: data)
        guard try Array(r.bytes(4)) == magic else {
            // A file shorter than the magic is truncated, not mis-tagged.
            throw data.count < 4 ? ArchiveError.truncated : ArchiveError.badMagic
        }
        let ver: UInt32 = try r.int()
        guard ver == version else { throw ArchiveError.unsupportedVersion(ver) }
        let n64: UInt64 = try r.int()
        let dateBits: UInt64 = try r.int()
        let rootLen: UInt32 = try r.int()
        let rootBytes = try r.bytes(Int(rootLen))

        // Every node costs at least this many bytes; reject counts the file can't hold.
        let perNode = 4 * 3 + 8 * 2 + 2 + 8 + 4 + 4 + 2
        guard n64 <= UInt64(r.remaining / perNode) else { throw ArchiveError.truncated }
        let n = Int(n64)
        guard n > 0 else { throw ArchiveError.truncated }

        let parents: [Int32] = try r.array(n)
        let firstChild: [Int32] = try r.array(n)
        let childCount: [Int32] = try r.array(n)
        let sizes: [Int64] = try r.array(n)
        let fileCounts: [Int64] = try r.array(n)
        let flagBits: [UInt16] = try r.array(n)
        let inodes: [UInt64] = try r.array(n)
        let devices: [Int32] = try r.array(n)
        let nameOffset: [UInt32] = try r.array(n)
        let nameLength: [UInt16] = try r.array(n)
        let namesCount: UInt64 = try r.int()
        guard namesCount <= UInt64(r.remaining) else { throw ArchiveError.truncated }
        let names = [UInt8](try r.bytes(Int(namesCount)))

        // Reject garbled contents that would trap or loop forever in FileTree accessors:
        // enforce the BFS invariant (parents precede children, ranges are consistent).
        guard parents[0] == -1 else { throw ArchiveError.truncated }
        for i in 0 ..< n {
            guard Int(nameOffset[i]) + Int(nameLength[i]) <= names.count,
                  i == 0 || (parents[i] >= 0 && Int(parents[i]) < i),
                  childCount[i] >= 0
            else { throw ArchiveError.truncated }
            if childCount[i] > 0 {
                let first = Int(firstChild[i]), end = first + Int(childCount[i])
                guard first > i, end <= n else { throw ArchiveError.truncated }
                for c in first ..< end where Int(parents[c]) != i { throw ArchiveError.truncated }
            }
        }

        return FileTree(
            rootPath: String(decoding: rootBytes, as: UTF8.self),
            scanDate: Date(timeIntervalSince1970: Double(bitPattern: dateBits)),
            parents: parents, firstChild: firstChild, childCount: childCount,
            sizes: sizes, fileCounts: fileCounts, flagBits: flagBits, inodes: inodes,
            devices: devices, nameOffset: nameOffset, nameLength: nameLength, names: names)
    }

    private static func put<T: FixedWidthInteger>(_ data: inout Data, _ v: T) {
        withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func putArray<T: FixedWidthInteger>(_ data: inout Data, _ a: [T]) {
        // Little-endian hosts only (all supported macOS targets).
        a.withUnsafeBytes { data.append(contentsOf: $0) }
    }

    private struct Reader {
        let data: Data
        var pos = 0
        init(data: Data) { self.data = data }
        var remaining: Int { data.count - pos }

        mutating func bytes(_ count: Int) throws -> Data {
            guard count >= 0, count <= remaining else { throw ArchiveError.truncated }
            let start = data.startIndex + pos
            pos += count
            return data[start ..< start + count]
        }

        mutating func int<T: FixedWidthInteger>() throws -> T {
            let b = try bytes(MemoryLayout<T>.size)
            var v: T = 0
            withUnsafeMutableBytes(of: &v) { $0.copyBytes(from: b) }
            return T(littleEndian: v)
        }

        mutating func array<T: FixedWidthInteger>(_ n: Int) throws -> [T] {
            let (size, overflow) = n.multipliedReportingOverflow(by: MemoryLayout<T>.stride)
            guard !overflow else { throw ArchiveError.truncated }
            let b = try bytes(size)
            return [T](unsafeUninitializedCapacity: n) { buf, initialized in
                UnsafeMutableRawBufferPointer(buf).copyBytes(from: b)
                initialized = n
            }
        }
    }
}
