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
    /// True for a directory that is a mount point (`DIR_MNTSTATUS_MNTPOINT`);
    /// always false for non-directories.
    public var isMountPoint: Bool = false
    /// The larger of the entry's mtime and ctime, in Unix seconds; 0 when not returned.
    public var modified: Int64 = 0
}

public enum ReadError: Error, Equatable {
    /// `permissionDenied`: file ownership or mode (EACCES), root can read it.
    /// `notPermitted`: macOS privacy protection (EPERM), only Full Disk Access opens it.
    case notFound, permissionDenied, notPermitted, notDirectory, other(Int32)

    init(errno code: Int32) {
        switch code {
        case ENOENT: self = .notFound
        case EACCES: self = .permissionDenied
        case EPERM: self = .notPermitted
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
    private static let baseFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC

    /// Opens a scan root. Follows a symlinked root (no O_NOFOLLOW).
    public static func open(path: String) throws(ReadError) -> DirectoryHandle {
        let fd = Darwin.open(path, baseFlags)
        guard fd >= 0 else { throw ReadError(errno: errno) }
        return DirectoryHandle(fd: fd)
    }

    /// Opens `name` relative to `parent` (works for paths longer than PATH_MAX).
    /// Never follows a symlink.
    public static func open(name: String, in parent: borrowing DirectoryHandle) throws(ReadError) -> DirectoryHandle {
        let fd = openat(parent.fd, name, baseFlags | O_NOFOLLOW)
        guard fd >= 0 else { throw ReadError(errno: errno) }
        return DirectoryHandle(fd: fd)
    }

    private static let bufferSize = 256 * 1024
    /// No FSOPT_PACK_INVAL_ATTRS: without it `returned_attrs` describes the
    /// record layout exactly (absent attributes occupy no space).
    private static let options = UInt64(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)
    private static let headerSize = MemoryLayout<UInt32>.size + MemoryLayout<attribute_set_t>.size

    public static func entries(of dir: borrowing DirectoryHandle) throws(ReadError) -> [RawEntry] {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_CHGTIME
                | ATTR_CMN_FILEID)
        request.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
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
            var position = 0
            for _ in 0..<count {
                guard bufferSize - position >= headerSize else { throw ReadError.other(EIO) }
                let record = UnsafeRawPointer(buffer + position)
                let length = Int(record.load(as: UInt32.self))
                guard length >= headerSize, length <= bufferSize - position else { throw ReadError.other(EIO) }
                if let entry = try parse(UnsafeRawBufferPointer(start: record, count: length)),
                   entry.name != ".", entry.name != ".." {
                    result.append(entry)
                }
                position += length
            }
        }
        return result
    }

    /// Parses one getattrlistbulk record (`record` spans exactly its length).
    /// Attributes appear in bitmask order (common, directory, file, then
    /// extended-common in the fork slot); attributes not set in
    /// `returned_attrs` occupy no space. Any read outside the record throws `.other(EIO)`.
    private static func parse(_ record: UnsafeRawBufferPointer) throws(ReadError) -> RawEntry? {
        var offset = MemoryLayout<UInt32>.size  // record length
        func read<T>(_: T.Type) throws(ReadError) -> T {
            guard record.count - offset >= MemoryLayout<T>.size else { throw ReadError.other(EIO) }
            defer { offset += MemoryLayout<T>.size }
            return record.loadUnaligned(fromByteOffset: offset, as: T.self)
        }
        func has(_ group: attrgroup_t, _ bit: Int32) -> Bool { group & attrgroup_t(bit) != 0 }

        let returned = try read(attribute_set_t.self)
        guard has(returned.commonattr, ATTR_CMN_NAME) else { return nil }
        let nameRefOffset = offset
        let nameRef = try read(attrreference_t.self)
        let nameStart = nameRefOffset + Int(nameRef.attr_dataoffset)
        var nameLength = Int(nameRef.attr_length)
        guard nameStart >= 0, nameStart <= record.count, nameLength <= record.count - nameStart else {
            throw ReadError.other(EIO)
        }
        if nameLength > 0, record[nameStart + nameLength - 1] == 0 {
            nameLength -= 1  // drop NUL terminator
        }
        let name = String(decoding: record[nameStart..<(nameStart + nameLength)], as: UTF8.self)

        let device = has(returned.commonattr, ATTR_CMN_DEVID) ? try read(dev_t.self) : 0
        let objType = has(returned.commonattr, ATTR_CMN_OBJTYPE) ? try read(fsobj_type_t.self) : VNON.rawValue
        let mtime = has(returned.commonattr, ATTR_CMN_MODTIME) ? try read(timespec.self) : timespec()
        let ctime = has(returned.commonattr, ATTR_CMN_CHGTIME) ? try read(timespec.self) : timespec()
        let inode = has(returned.commonattr, ATTR_CMN_FILEID) ? try read(UInt64.self) : 0

        let mountStatus = has(returned.dirattr, ATTR_DIR_MOUNTSTATUS) ? try read(UInt32.self) : 0

        let linkCount = has(returned.fileattr, ATTR_FILE_LINKCOUNT) ? try read(UInt32.self) : 1
        let allocated = has(returned.fileattr, ATTR_FILE_ALLOCSIZE) ? try read(off_t.self) : 0

        let cloneID = has(returned.forkattr, ATTR_CMNEXT_CLONEID) ? try read(UInt64.self) : 0
        let cloneRefCount = has(returned.forkattr, ATTR_CMNEXT_CLONE_REFCNT) ? try read(UInt32.self) : 0

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
            cloneID: cloneID, cloneRefCount: cloneRefCount,
            isMountPoint: kind == .directory && mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0,
            modified: Int64(max(mtime.tv_sec, ctime.tv_sec)))
    }
}
