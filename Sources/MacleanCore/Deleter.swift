import Darwin
import Foundation

/// One item to delete, with the identity and measurements it had when scanned.
public struct DeleteRequest: Sendable, Hashable, Codable {
    public let path: String
    public let inode: UInt64
    public let device: Int32
    /// Allocated bytes when scanned.
    public let size: Int64
    /// Non-directory items when scanned (1 for a file or symlink).
    public let fileCount: Int64
    public let isDirectory: Bool

    public init(path: String, inode: UInt64, device: Int32, size: Int64, fileCount: Int64, isDirectory: Bool) {
        self.path = path
        self.inode = inode
        self.device = device
        self.size = size
        self.fileCount = fileCount
        self.isDirectory = isDirectory
    }
}

public enum DeleteMode: String, Sendable, Codable { case permanent, trash }

public enum DeleteOutcome: Sendable, Equatable, Codable {
    /// Removed (or, in trash mode, moved to the Trash); `freed` is the measured size.
    case deleted(freed: Int64)
    /// The item's contents differ from the request beyond tolerance; nothing was touched.
    case changedSinceScan(size: Int64, fileCount: Int64)
    /// Something else now sits at the path (inode or device differ); nothing was touched.
    case replaced
    /// Nothing at the path any more.
    case missing
    case refused(Refusal)
    /// `EACCES`/`EPERM`; `started` is true when part of the item was already removed.
    /// `verified` is true when the item couldn't be read in full but all that
    /// could be read matches the scan (or nothing inside it was readable,
    /// then or now): the administrator step may then skip its own re-walk,
    /// which would see the formerly unreadable contents and call it changed.
    case needsAdmin(started: Bool, verified: Bool = false)
    case failed(String)
}

/// Deletes collected items safely.
///
/// Per item: the protection rules are checked again; the item is found with
/// `fstatat(AT_SYMLINK_NOFOLLOW)` relative to its opened parent and must
/// still have the requested inode and device; unless forced, it is re-measured
/// and must match the request within tolerance. A permanent delete then
/// removes it bottom-up with `unlinkat` relative to directory fds opened with
/// `O_NOFOLLOW`, so a symlink swapped in at any level is removed as a link and
/// never followed. A symlink item is deleted as the link itself. Removal never
/// crosses onto another device.
public struct Deleter: Sendable {
    public let mode: DeleteMode
    public let environment: ProtectionEnvironment
    /// Test seam: receives the item's location in the Trash after a trash-mode delete.
    let trashed: (@Sendable (URL) -> Void)?

    public init(mode: DeleteMode, environment: ProtectionEnvironment) {
        self.init(mode: mode, environment: environment, trashed: nil)
    }

    init(mode: DeleteMode, environment: ProtectionEnvironment, trashed: (@Sendable (URL) -> Void)?) {
        self.mode = mode
        self.environment = environment
        self.trashed = trashed
    }

    /// Deletes `request`'s item. `force` skips the changed-since-scan re-walk
    /// (the identity check still runs); `freed` is then `request.size`.
    public func delete(_ request: DeleteRequest, force: Bool = false) async -> DeleteOutcome {
        if let refusal = ProtectionRules.refusal(for: request.path, context: .collector, in: environment) {
            return .refused(refusal)
        }
        let pfd: Int32
        switch Self.openParent(of: request.path) {
        case .failure(let early): return early.outcome
        case .success(let fd): pfd = fd
        }
        defer { close(pfd) }
        return await delete(request, force: force, parentFD: pfd)
    }

    /// Deletes `request`'s item relative to `parentFD`, an open directory fd
    /// for the item's parent (the caller keeps ownership and closes it). The
    /// identity check and a permanent removal happen relative to this fd, so
    /// a caller that checked the fd's real location (`F_GETPATH`) deletes
    /// exactly there, even if an ancestor of the path is swapped meanwhile.
    /// (The changed-since-scan re-walk and a trash-mode move still go by path;
    /// the identity check guards both.)
    public func delete(_ request: DeleteRequest, force: Bool = false, parentFD pfd: Int32) async -> DeleteOutcome {
        if let refusal = ProtectionRules.refusal(for: request.path, context: .collector, in: environment) {
            return .refused(refusal)
        }
        guard let (_, name) = Self.split(request.path) else { return .refused(.unsafePath) }

        var st: stat
        switch Self.identity(pfd, name, request) {
        case .failure(let o): return o.outcome
        case .success(let s): st = s
        }

        var freed = request.size
        if !force {
            if Self.isDirectory(st) {
                switch await Self.scanForRewalk(request.path, mode: mode) {
                case .failure(let early): return early.outcome
                case .success(nil):
                    break  // Unreadable item, trash mode: moving it needs no read access.
                case .success(let tree?):
                    if let verdict = Self.rewalkVerdict(request, tree: tree, mode: mode) { return verdict }
                    freed = tree.size(of: tree.root)
                }
            } else {
                let size = Int64(st.st_blocks) * 512
                if Self.changed(request, size: size, fileCount: 1) { return .changedSinceScan(size: size, fileCount: 1) }
                freed = size
            }
            // The re-walk may have taken a while: check the identity again.
            switch Self.identity(pfd, name, request) {
            case .failure(let o): return o.outcome
            case .success(let s): st = s
            }
        }

        let isDir = Self.isDirectory(st)
        let mode = self.mode, trashed = self.trashed, path = request.path, measured = freed
        let expected = (inode: request.inode, device: request.device)
        return await Self.blocking {
            switch mode {
            case .trash:
                return Self.trash(path, freed: measured, trashed: trashed)
            case .permanent:
                var remover = Remover(device: expected.device)
                do throws(RemoveError) {
                    if isDir {
                        try remover.removeTree(pfd, name, expectIno: expected.inode, top: true)
                    } else {
                        try remover.unlink(pfd, name, 0)
                    }
                    return .deleted(freed: measured)
                } catch {
                    switch error {
                    case .replaced: return remover.started ? .failed("Item changed while being deleted") : .replaced
                    case .otherDisk(let disk): return .failed("Contains another disk: \(disk)")
                    case .errno(let code): return Self.outcome(errno: code, started: remover.started)
                    }
                }
            }
        }
    }

    // MARK: - Checks

    /// What the re-walk `tree` of a directory item says about deleting it,
    /// or nil when it may be deleted.
    ///
    /// The scan recorded unreadable folders as empty, so the readable part is
    /// compared first: a change there is a real change. Unchanged but with
    /// unreadable folders, a permanent delete needs administrator rights and
    /// is `verified` (root may skip its re-walk). Moving to the Trash needs
    /// only write access on the parent, so trash mode ignores unreadable
    /// folders.
    static func rewalkVerdict(_ request: DeleteRequest, tree: FileTree,
                              mode: DeleteMode = .permanent) -> DeleteOutcome? {
        if tree.inode(of: tree.root) != request.inode || tree.device(of: tree.root) != request.device {
            return .replaced
        }
        if let disk = otherDisk(in: tree) { return .failed("Contains another disk: \(disk)") }
        let size = tree.size(of: tree.root), files = tree.fileCount(of: tree.root)
        if changed(request, size: size, fileCount: files) { return .changedSinceScan(size: size, fileCount: files) }
        if mode == .permanent,
           (0..<tree.count).contains(where: { tree.flags(of: NodeID(index: Int32($0))).contains(.restricted) }) {
            return .needsAdmin(started: false, verified: true)
        }
        return nil
    }

    /// The re-walk of directory item `path`, nil when the item itself can't
    /// be read in trash mode, or the outcome to report. An item unreadable at
    /// its top level has nothing to verify as the user: in permanent mode it
    /// needs administrator rights, `verified`.
    private static func scanForRewalk(_ path: String, mode: DeleteMode) async -> Result<FileTree?, Early> {
        do {
            return .success(try await Scanner.scan(path: path))
        } catch ReadError.permissionDenied {
            return mode == .trash ? .success(nil) : .failure(Early(outcome: .needsAdmin(started: false, verified: true)))
        } catch {
            return .failure(Early(outcome: outcome(scanError: error)))
        }
    }

    /// Name of the first mount point inside `tree` (its root excluded): a disk
    /// the item contains that the delete must never cross into.
    static func otherDisk(in tree: FileTree) -> String? {
        for i in 1..<max(tree.count, 1) {
            let id = NodeID(index: Int32(i))
            if tree.flags(of: id).contains(.mountPoint) { return tree.name(of: id) }
        }
        return nil
    }

    /// Any file-count difference, or a size difference above 1% or 1 MB,
    /// whichever is larger (caches churn a little all the time).
    static func changed(_ request: DeleteRequest, size: Int64, fileCount: Int64) -> Bool {
        fileCount != request.fileCount || abs(size - request.size) > max(request.size / 100, 1_048_576)
    }

    struct Early: Error { let outcome: DeleteOutcome }

    /// Opens `path`'s parent directory (following symlinks, as a path open
    /// does), or the outcome to report when that fails. The parent fd pins
    /// the directory the identity check runs in.
    static func openParent(of path: String) -> Result<Int32, Early> {
        guard let (parent, _) = split(path) else { return .failure(Early(outcome: .refused(.unsafePath))) }
        let fd = open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return .failure(Early(outcome: outcome(errno: errno, started: false))) }
        return .success(fd)
    }

    private static func identity(_ pfd: Int32, _ name: [CChar], _ request: DeleteRequest) -> Result<stat, Early> {
        var st = stat()
        let rc = name.withUnsafeBufferPointer { fstatat(pfd, $0.baseAddress!, &st, AT_SYMLINK_NOFOLLOW) }
        guard rc == 0 else { return .failure(Early(outcome: outcome(errno: errno, started: false))) }
        guard UInt64(st.st_ino) == request.inode, st.st_dev == request.device else {
            return .failure(Early(outcome: .replaced))
        }
        return .success(st)
    }

    // MARK: - Removal

    private static func trash(_ path: String, freed: Int64, trashed: (@Sendable (URL) -> Void)?) -> DeleteOutcome {
        var result: NSURL?
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &result)
        } catch {
            let ns = error as NSError
            let posix = ns.domain == NSPOSIXErrorDomain ? ns
                : (ns.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? $0 : nil }
            if let code = posix?.code { return outcome(errno: Int32(code), started: false) }
            if ns.domain == NSCocoaErrorDomain {
                if ns.code == NSFileWriteNoPermissionError { return .needsAdmin(started: false) }
                if ns.code == NSFileNoSuchFileError { return .missing }
            }
            return .failed(ns.localizedDescription)
        }
        if let url = result as URL? { trashed?(url) }
        return .deleted(freed: freed)
    }

    private enum RemoveError: Error { case errno(Int32), replaced, otherDisk(String) }

    private struct Remover {
        let device: Int32
        /// Whether anything has been removed yet.
        var started = false

        mutating func unlink(_ dfd: Int32, _ name: [CChar], _ flags: Int32) throws(RemoveError) {
            let rc = name.withUnsafeBufferPointer { unlinkat(dfd, $0.baseAddress!, flags) }
            guard rc == 0 else { throw .errno(errno) }
            started = true
        }

        /// Removes directory `name` in `pfd` bottom-up. Every directory is
        /// opened with `O_NOFOLLOW` relative to its parent's fd and must keep
        /// the inode it was seen with and the item's device.
        mutating func removeTree(_ pfd: Int32, _ name: [CChar], expectIno: UInt64, top: Bool) throws(RemoveError) {
            let fd = name.withUnsafeBufferPointer {
                openat(pfd, $0.baseAddress!, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            if fd < 0 {
                let e = errno
                if e == ELOOP || e == ENOTDIR {
                    // It became a symlink or file. Inside the item that's
                    // still the item's content: remove it as is. The item
                    // itself was approved as a directory: leave it alone.
                    if top { throw .replaced }
                    try unlink(pfd, name, 0)
                    return
                }
                if e == ENOENT && !top { return }
                throw .errno(e)
            }
            do throws(RemoveError) {
                try removeContents(fd, name: name, expectIno: expectIno)
            } catch {
                close(fd)
                throw error
            }
            close(fd)
            try unlink(pfd, name, AT_REMOVEDIR)
        }

        private mutating func removeContents(_ fd: Int32, name: [CChar], expectIno: UInt64) throws(RemoveError) {
            var st = stat()
            guard fstat(fd, &st) == 0 else { throw .errno(errno) }
            guard UInt64(st.st_ino) == expectIno else { throw .replaced }
            guard st.st_dev == device else { throw .otherDisk(Deleter.string(name)) }
            for child in try Deleter.entries(fd) {
                var cst = stat()
                let rc = child.withUnsafeBufferPointer { fstatat(fd, $0.baseAddress!, &cst, AT_SYMLINK_NOFOLLOW) }
                if rc != 0 {
                    if errno == ENOENT { continue }
                    throw .errno(errno)
                }
                if Deleter.isDirectory(cst) {
                    guard cst.st_dev == device else { throw .otherDisk(Deleter.string(child)) }
                    try removeTree(fd, child, expectIno: UInt64(cst.st_ino), top: false)
                } else {
                    do throws(RemoveError) { try unlink(fd, child, 0) } catch {
                        if case .errno(ENOENT) = error { continue }
                        throw error
                    }
                }
            }
        }
    }

    /// The entry names of directory `fd` (without `.` and `..`), as raw
    /// NUL-terminated bytes so names that aren't valid UTF-8 survive, in byte
    /// order. Read in full before anything is removed.
    private static func entries(_ fd: Int32) throws(RemoveError) -> [[CChar]] {
        let copy = dup(fd)
        guard copy >= 0 else { throw .errno(errno) }
        guard let dir = fdopendir(copy) else {
            let e = errno
            close(copy)
            throw .errno(e)
        }
        defer { closedir(dir) }
        rewinddir(dir)
        var names: [[CChar]] = []
        errno = 0
        while let entry = readdir(dir) {
            var ent = entry.pointee
            let length = Int(ent.d_namlen)
            let name: [CChar] = withUnsafeBytes(of: &ent.d_name) { Array($0.bindMemory(to: CChar.self).prefix(length)) + [0] }
            if name != [46, 0] && name != [46, 46, 0] { names.append(name) }
        }
        if errno != 0 { throw .errno(errno) }
        return names.sorted { $0.lexicographicallyPrecedes($1) }
    }

    // MARK: - Helpers

    private static func isDirectory(_ st: stat) -> Bool { st.st_mode & S_IFMT == S_IFDIR }

    private static func string(_ name: [CChar]) -> String {
        String(decoding: name.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The parent directory and the NUL-terminated last component of an absolute path.
    static func split(_ path: String) -> (String, [CChar])? {
        guard let slash = path.lastIndex(of: "/") else { return nil }
        let name = path[path.index(after: slash)...]
        guard !name.isEmpty else { return nil }
        let parent = slash == path.startIndex ? "/" : String(path[..<slash])
        return (parent, Array(String(name).utf8CString))
    }

    private static func outcome(errno code: Int32, started: Bool) -> DeleteOutcome {
        switch code {
        case ENOENT where !started: .missing
        case EACCES, EPERM: .needsAdmin(started: started)
        default: .failed(String(cString: strerror(code)))
        }
    }

    private static func outcome(scanError error: any Error) -> DeleteOutcome {
        switch error as? ReadError {
        case .notFound: .missing
        case .permissionDenied: .needsAdmin(started: false)
        case .notDirectory: .replaced
        case .other(let code): .failed(String(cString: strerror(code)))
        case nil: error is CancellationError ? .failed("Cancelled") : .failed(String(describing: error))
        }
    }

    /// Runs blocking file-system work off Swift's cooperative pool.
    private static func blocking(_ work: @escaping @Sendable () -> DeleteOutcome) async -> DeleteOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }
}
