import Darwin
import Foundation

/// Size, file count and newest timestamp of one item or subtree.
public struct Measurement: Sendable, Equatable, Codable {
    /// Allocated bytes, after hard-link and clone de-duplication within the `MeasureContext`.
    public var size: Int64
    /// Non-directory entries in the subtree (a file or symlink measures as 1).
    public var fileCount: Int64
    /// The newest mtime or ctime of the item and everything inside it.
    public var newest: Date
    public var inode: UInt64
    public var device: Int32
    public var isDirectory: Bool
    /// True when some subfolder could not be read, so the numbers are a lower bound.
    public var restricted: Bool
}

/// Shared de-duplication state: each hard-linked inode and each clone ID is
/// counted once across every `Measurer.measure` call that uses the same context
/// (the scanner's rule).
public final class MeasureContext: @unchecked Sendable {
    private struct Key: Hashable { let device: Int32; let id: UInt64 }
    private let lock = NSLock()
    private var hardLinks: Set<Key> = []
    private var clones: Set<Key> = []

    public init() {}

    /// Bytes to count for a non-directory entry.
    func billableSize(allocated: Int64, linkCount: UInt32, inode: UInt64, device: Int32,
                      cloneID: UInt64, cloneRefCount: UInt32) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        var extraLink = false
        if linkCount > 1, inode != 0, !hardLinks.insert(Key(device: device, id: inode)).inserted {
            extraLink = true
        }
        if extraLink { return 0 }
        if cloneRefCount > 1, cloneID != 0, !clones.insert(Key(device: device, id: cloneID)).inserted {
            return 0
        }
        return allocated
    }
}

public enum MeasureError: Error, Equatable { case timedOut, notFound, unreadable }

public enum Measurer {
    /// Measures `path` without following symlinks or crossing devices.
    /// Files and symlinks measure as themselves; directories are walked.
    /// An unreadable subfolder sets `restricted`; an unreadable top level throws `.unreadable`.
    /// The deadline is checked once per directory.
    public static func measure(_ path: String, context: MeasureContext,
                               deadline: ContinuousClock.Instant? = nil) throws(MeasureError) -> Measurement {
        var st = stat()
        guard lstat(path, &st) == 0 else { throw errno == ENOENT || errno == ENOTDIR ? .notFound : .unreadable }
        let isDir = st.st_mode & S_IFMT == S_IFDIR
        var result = Measurement(
            size: 0, fileCount: isDir ? 0 : 1,
            newest: Date(timeIntervalSince1970: Double(max(st.st_mtimespec.tv_sec, st.st_ctimespec.tv_sec))),
            inode: UInt64(st.st_ino), device: st.st_dev, isDirectory: isDir, restricted: false)
        if !isDir {
            result.size = context.billableSize(
                allocated: Int64(st.st_blocks) * 512, linkCount: UInt32(st.st_nlink), inode: UInt64(st.st_ino),
                device: st.st_dev, cloneID: 0, cloneRefCount: 0)
            return result
        }
        if let deadline, .now >= deadline { throw .timedOut }
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw errno == ENOENT ? .notFound : .unreadable }
        let handle = DirectoryHandle(fd: fd)
        var newest = Int64(result.newest.timeIntervalSince1970)
        let entries: [RawEntry]
        do { entries = try DirectoryReader.entries(of: handle) } catch { throw .unreadable }
        try walk(entries, in: handle, device: st.st_dev, context: context, deadline: deadline,
                 into: &result, newest: &newest)
        result.newest = Date(timeIntervalSince1970: Double(newest))
        return result
    }

    private static func walk(_ entries: [RawEntry], in handle: DirectoryHandle, device: Int32,
                             context: MeasureContext, deadline: ContinuousClock.Instant?,
                             into result: inout Measurement, newest: inout Int64) throws(MeasureError) {
        for e in entries {
            if e.device != device { continue }
            newest = max(newest, e.modified)
            switch e.kind {
            case .directory:
                if e.isMountPoint { continue }
                if let deadline, .now >= deadline { throw .timedOut }
                guard let sub = try? DirectoryReader.open(name: e.name, in: handle),
                      let subEntries = try? DirectoryReader.entries(of: sub) else {
                    result.restricted = true
                    continue
                }
                try walk(subEntries, in: sub, device: device, context: context, deadline: deadline,
                         into: &result, newest: &newest)
            case .symlink:
                result.fileCount += 1
                result.size += e.allocatedSize
            case .file, .other:
                result.fileCount += 1
                result.size += context.billableSize(
                    allocated: e.allocatedSize, linkCount: e.linkCount, inode: e.inode, device: e.device,
                    cloneID: e.cloneID, cloneRefCount: e.cloneRefCount)
            }
        }
    }
}
