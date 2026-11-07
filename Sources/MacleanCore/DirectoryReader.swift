import Darwin

public enum EntryKind: Sendable { case file, directory, symlink, other }

public struct RawEntry: Sendable {
    public var name: String
    public var kind: EntryKind
    public var inode: UInt64
    public var device: Int32
    /// Hard-link count for files; 1 for directories (not requested from the kernel).
    public var linkCount: UInt32
    /// Bytes allocated on disk; 0 for directories.
    public var allocatedSize: Int64
    /// APFS clone identity; 0 when unsupported.
    public var cloneID: UInt64
    /// Number of files sharing `cloneID`'s data; 0 when unsupported or not cloned.
    public var cloneRefCount: UInt32
}

public enum ReadError: Error, Equatable {
    case notFound, permissionDenied, notDirectory, other(Int32)

    init(errno code: Int32) {
        switch code {
        case ENOENT: self = .notFound
        case EACCES, EPERM: self = .permissionDenied
        case ENOTDIR: self = .notDirectory
        default: self = .other(code)
        }
    }
}

/// An open directory file descriptor, closed when the handle is deallocated.
///
/// A `Sendable` final class rather than a `~Copyable` struct so handles can be
/// shared across concurrent tasks (e.g. task-group children opening
/// subdirectories relative to a common parent).
public final class DirectoryHandle: Sendable {
    public let fd: Int32

    init(fd: Int32) { self.fd = fd }

    deinit { close(fd) }
}

public enum DirectoryReader {
    private static let openFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    public static func open(path: String) throws(ReadError) -> DirectoryHandle {
        let fd = Darwin.open(path, openFlags)
        guard fd >= 0 else { throw ReadError(errno: errno) }
        return DirectoryHandle(fd: fd)
    }

    /// Opens `name` relative to `parent` (works for paths longer than PATH_MAX).
    public static func open(name: String, in parent: borrowing DirectoryHandle) throws(ReadError) -> DirectoryHandle {
        let fd = openat(parent.fd, name, openFlags)
        guard fd >= 0 else { throw ReadError(errno: errno) }
        return DirectoryHandle(fd: fd)
    }

    private static let bufferSize = 256 * 1024
    private static let options = UInt64(FSOPT_PACK_INVAL_ATTRS | FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)

    public static func entries(of dir: borrowing DirectoryHandle) throws(ReadError) -> [RawEntry] {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID)
        request.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT)

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        var result: [RawEntry] = []
        while true {
            let count = getattrlistbulk(dir.fd, &request, buffer, bufferSize, options)
            if count < 0 {
                if errno == EINTR { continue }
                throw ReadError(errno: errno)
            }
            if count == 0 { break }
            var record = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(record.load(as: UInt32.self))
                if let entry = parse(record), entry.name != ".", entry.name != ".." {
                    result.append(entry)
                }
                record += length
            }
        }
        return result
    }

    /// Parses one getattrlistbulk record. Attributes appear in bitmask order
    /// (common, file, then extended-common in the fork slot); attributes not
    /// set in `returned_attrs` occupy no space (verified on APFS: directories
    /// carry no ATTR_FILE_* fields even with FSOPT_PACK_INVAL_ATTRS).
    private static func parse(_ record: UnsafeRawPointer) -> RawEntry? {
        var offset = MemoryLayout<UInt32>.size  // record length
        let returned = record.loadUnaligned(fromByteOffset: offset, as: attribute_set_t.self)
        offset += MemoryLayout<attribute_set_t>.size

        func read<T>(_: T.Type) -> T {
            defer { offset += MemoryLayout<T>.size }
            return record.loadUnaligned(fromByteOffset: offset, as: T.self)
        }
        func has(_ group: attrgroup_t, _ bit: Int32) -> Bool { group & attrgroup_t(bit) != 0 }

        guard has(returned.commonattr, ATTR_CMN_NAME) else { return nil }
        let nameRefOffset = offset
        let nameRef = read(attrreference_t.self)
        let nameStart = record + nameRefOffset + Int(nameRef.attr_dataoffset)
        var nameLength = Int(nameRef.attr_length)
        if nameLength > 0, nameStart.load(fromByteOffset: nameLength - 1, as: UInt8.self) == 0 {
            nameLength -= 1  // drop NUL terminator
        }
        let name = String(decoding: UnsafeRawBufferPointer(start: nameStart, count: nameLength), as: UTF8.self)

        let device = has(returned.commonattr, ATTR_CMN_DEVID) ? read(dev_t.self) : 0
        let objType = has(returned.commonattr, ATTR_CMN_OBJTYPE) ? read(fsobj_type_t.self) : VNON.rawValue
        let inode = has(returned.commonattr, ATTR_CMN_FILEID) ? read(UInt64.self) : 0

        let linkCount = has(returned.fileattr, ATTR_FILE_LINKCOUNT) ? read(UInt32.self) : 1
        let allocated = has(returned.fileattr, ATTR_FILE_ALLOCSIZE) ? read(off_t.self) : 0

        let cloneID = has(returned.forkattr, ATTR_CMNEXT_CLONEID) ? read(UInt64.self) : 0
        let cloneRefCount = has(returned.forkattr, ATTR_CMNEXT_CLONE_REFCNT) ? read(UInt32.self) : 0

        let kind: EntryKind
        switch objType {
        case VREG.rawValue: kind = .file
        case VDIR.rawValue: kind = .directory
        case VLNK.rawValue: kind = .symlink
        default: kind = .other
        }
        return RawEntry(
            name: name, kind: kind, inode: inode, device: device,
            linkCount: linkCount, allocatedSize: kind == .directory ? 0 : allocated,
            cloneID: cloneID, cloneRefCount: cloneRefCount)
    }
}
