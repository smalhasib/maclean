import Darwin
import Foundation

public struct ScanProgress: Sendable {
    /// Allocated bytes counted so far (after hard-link and clone de-duplication).
    public var bytes: Int64
    /// Entries (files, directories, symlinks, ...) seen so far.
    public var items: Int64
    /// The directory most recently read.
    public var currentPath: String
}

/// Parallel directory-tree scanner.
///
/// Directory reads run concurrently in a task group (at most
/// `activeProcessorCount * 2` in flight); a single consumer — the scanning
/// task itself — appends results to the non-thread-safe `FileTreeBuilder` and
/// schedules child directories depth-first.
///
/// Every directory is opened with `openat` relative to an open ancestor, so
/// full paths are never passed to the kernel (no PATH_MAX limit). A directory
/// keeps its fd open only while it still has undispatched child directories
/// and the fd budget allows; otherwise its children are reopened name by name
/// from the nearest ancestor that is still open.
public enum Scanner {
    /// Scans `path` with `ScanBoundary.forRoot` of its canonical path.
    public static func scan(path: String,
                            progress: @Sendable (ScanProgress) -> Void = { _ in }) async throws -> FileTree {
        let rootPath = try canonicalRoot(path)
        return try await scan(path: rootPath, boundary: .forRoot(rootPath), progress: progress)
    }

    /// Scans `path` (canonicalized with `realpath`; the tree's `rootPath` is
    /// the canonical path), descending only into directories `boundary`
    /// allows. Directories that are mount points are recorded as empty
    /// `.mountPoint` nodes and never opened. Only a root that cannot be
    /// resolved or opened throws (a `ReadError`); unreadable subdirectories
    /// become `.restricted` nodes. Throws `CancellationError` when the calling
    /// task is cancelled.
    public static func scan(path: String, boundary: ScanBoundary,
                            progress: @Sendable (ScanProgress) -> Void = { _ in }) async throws -> FileTree {
        try Task.checkCancellation()
        let rootPath = try canonicalRoot(path)
        let rootHandle = try DirectoryReader.open(path: rootPath)
        var st = stat()
        let ok = fstat(rootHandle.fd, &st) == 0
        let rootInode = ok ? UInt64(st.st_ino) : 0
        let rootDevice = ok ? st.st_dev : 0

        return try await withThrowingTaskGroup(of: (Int, Outcome).self) { group in
            var walk = Walk(rootPath: rootPath, rootInode: rootInode, rootDevice: rootDevice,
                            rootHandle: rootHandle, boundary: boundary)
            let allowed = boundary.allowedDevices
            var clock = ProgressClock()

            group.addTask { (Walk.rootToken, read(anchor: rootHandle, path: [], allowed: nil)) }
            var inFlight = 1

            while let (token, outcome) = try await group.next() {
                inFlight -= 1
                if Task.isCancelled { throw CancellationError() }
                if let current = walk.handle(token: token, outcome: outcome), clock.due() {
                    progress(ScanProgress(bytes: walk.bytes, items: walk.items,
                                          currentPath: walk.path(of: current)))
                }
                while inFlight < walk.maxInFlight, let job = walk.nextJob() {
                    group.addTask { (job.token, read(anchor: job.anchor, path: job.path, allowed: allowed)) }
                    inFlight += 1
                }
            }
            return walk.builder.finish()
        }
    }

    // MARK: - Job (runs concurrently)

    enum Outcome: Sendable {
        case listed(DirectoryHandle, inode: UInt64, device: Int32, [RawEntry])
        case otherDevice(inode: UInt64, device: Int32)
        case failed(ReadError)
    }

    /// Opens `path` (names relative to `anchor`, never following symlinks),
    /// checks its device against `allowed` (nil: no check) and lists it.
    static func read(anchor: DirectoryHandle, path: [String], allowed: Set<Int32>?) -> Outcome {
        if Task.isCancelled { return .failed(.other(ECANCELED)) }
        var handle = anchor
        do {
            for name in path { handle = try DirectoryReader.open(name: name, in: handle) }
        } catch {
            return .failed(error)
        }
        var st = stat()
        guard fstat(handle.fd, &st) == 0 else { return .failed(ReadError(errno: errno)) }
        // Entries report their parent's device even for mount points, so the
        // boundary is enforced here, on the opened directory itself.
        if let allowed, !allowed.contains(st.st_dev) {
            return .otherDevice(inode: UInt64(st.st_ino), device: st.st_dev)
        }
        do {
            return .listed(handle, inode: UInt64(st.st_ino), device: st.st_dev,
                           try DirectoryReader.entries(of: handle))
        } catch {
            return .failed(error)
        }
    }

    static func canonicalRoot(_ path: String) throws(ReadError) -> String {
        guard let resolved = ScanBoundary.canonicalPath(path) else { throw ReadError(errno: errno) }
        return resolved
    }
}

// MARK: - Consumer state (single-threaded)

/// A directory whose children are still being scheduled. Forms a parent
/// chain so a child can be reopened from the nearest ancestor holding an fd.
private final class DirRef {
    let parent: DirRef?
    let name: String
    let node: NodeID
    /// Number of path components below the scan root.
    let depth: Int
    var handle: DirectoryHandle?
    var undispatched = 0

    init(parent: DirRef?, name: String, node: NodeID, depth: Int, handle: DirectoryHandle?) {
        self.parent = parent
        self.name = name
        self.node = node
        self.depth = depth
        self.handle = handle
    }
}

private struct Pending {
    let parent: DirRef
    let entry: RawEntry
}

private struct Job: Sendable {
    let token: Int
    let anchor: DirectoryHandle
    let path: [String]
}

private struct LinkKey: Hashable {
    let device: Int32
    let id: UInt64
}

private struct Walk {
    static let rootToken = 0

    let builder: FileTreeBuilder
    let rootPath: String
    let boundary: ScanBoundary
    let maxInFlight: Int
    /// Directories other than the root that may keep an fd open.
    let maxRetained: Int
    /// Deepest skipped path, in components below the root (paths are only
    /// built for directories this shallow).
    let maxSkipDepth: Int

    private let rootRef: DirRef
    private var stack: [Pending] = []
    private var inFlight: [Int: Pending] = [:]
    private var nextToken = 1
    private var retained = 0
    private var hardLinks: Set<LinkKey> = []
    private var clones: Set<LinkKey> = []
    private(set) var bytes: Int64 = 0
    private(set) var items: Int64 = 0

    init(rootPath: String, rootInode: UInt64, rootDevice: Int32, rootHandle: DirectoryHandle,
         boundary: ScanBoundary) {
        builder = FileTreeBuilder(rootPath: rootPath, rootInode: rootInode, rootDevice: rootDevice)
        self.rootPath = rootPath
        self.boundary = boundary
        rootRef = DirRef(parent: nil, name: rootPath, node: builder.root, depth: 0, handle: rootHandle)

        var limit = rlimit()
        let soft = getrlimit(RLIMIT_NOFILE, &limit) == 0 ? Int(clamping: limit.rlim_cur) : 256
        // In flight, each job holds at most two fds (while walking a reopen
        // chain), plus the retained ones: ~soft/2 at worst for the default 256.
        maxInFlight = max(2, min(ProcessInfo.processInfo.activeProcessorCount * 2, soft / 8))
        maxRetained = max(4, min(128, soft / 8))

        let rootComponents = rootPath.split(separator: "/").count
        maxSkipDepth = boundary.skippedPaths
            .map { $0.split(separator: "/").count - rootComponents }
            .max() ?? 0
    }

    /// Records a finished job. Returns the directory when it was read.
    mutating func handle(token: Int, outcome: Scanner.Outcome) -> DirRef? {
        let parent: DirRef?
        let entry: RawEntry?
        if token == Self.rootToken {
            (parent, entry) = (nil, nil)
        } else {
            let pending = inFlight.removeValue(forKey: token)!
            (parent, entry) = (pending.parent, pending.entry)
        }

        switch outcome {
        case .failed(.notFound):
            return nil  // vanished since its parent was listed
        case .failed:
            if let parent, let entry {
                addDirectory(entry, in: parent, flags: .restricted)
            } else {
                builder.markRestricted(builder.root)
            }
            return nil
        case let .otherDevice(inode, device):
            if let parent, let entry {
                var e = entry
                (e.inode, e.device) = (inode, device)
                addDirectory(e, in: parent, flags: [])
            }
            return nil
        case let .listed(handle, inode, device, entries):
            let ref: DirRef
            if let parent, let entry {
                var e = entry
                (e.inode, e.device) = (inode, device)
                let node = addDirectory(e, in: parent, flags: [])
                ref = DirRef(parent: parent, name: e.name, node: node, depth: parent.depth + 1, handle: nil)
            } else {
                ref = rootRef
            }
            add(entries, in: ref)
            if ref !== rootRef, ref.undispatched > 0, retained < maxRetained {
                ref.handle = handle
                retained += 1
            }
            return ref
        }
    }

    /// Pops the next directory to read (depth-first), with the nearest open
    /// ancestor as anchor and the names leading from it.
    mutating func nextJob() -> Job? {
        guard let pending = stack.popLast() else { return nil }
        var names = [pending.entry.name]
        var anchor = pending.parent
        while anchor.handle == nil {
            names.append(anchor.name)
            anchor = anchor.parent!  // the root always holds its handle
        }
        let job = Job(token: nextToken, anchor: anchor.handle!, path: names.reversed())
        inFlight[nextToken] = pending
        nextToken += 1

        let parent = pending.parent
        parent.undispatched -= 1
        if parent.undispatched == 0, parent !== rootRef, parent.handle != nil {
            parent.handle = nil  // in-flight jobs keep their own reference
            retained -= 1
        }
        return job
    }

    private mutating func add(_ entries: [RawEntry], in ref: DirRef) {
        let checkSkips = ref.depth < maxSkipDepth
        let base = checkSkips ? path(of: ref) : ""
        for e in entries {
            items += 1
            switch e.kind {
            case .directory:
                // Mount points are never opened: crossing into another volume
                // could trigger an automount or hang on a stale network mount.
                if e.isMountPoint {
                    addDirectory(e, in: ref, flags: .mountPoint)
                } else if checkSkips, boundary.skippedPaths.contains(join(base, e.name)) {
                    addDirectory(e, in: ref, flags: [])
                } else {
                    stack.append(Pending(parent: ref, entry: e))
                    ref.undispatched += 1
                }
            case .symlink:
                bytes += e.allocatedSize
                builder.add(parent: ref.node, name: e.name, size: e.allocatedSize, flags: .symlink,
                            inode: e.inode, device: e.device)
            case .file, .other:
                var size = e.allocatedSize
                var flags: NodeFlags = []
                var extraLink = false
                if e.linkCount > 1, e.inode != 0 {
                    if hardLinks.insert(LinkKey(device: e.device, id: e.inode)).inserted {
                        flags.insert(.hardLinkFirst)
                    } else {
                        flags.insert(.hardLinkExtra)
                        size = 0
                        extraLink = true
                    }
                }
                // A hard link to a cloned file also reports cloneRefCount > 1,
                // so only links not already counted as extras are checked.
                if !extraLink, e.cloneRefCount > 1, e.cloneID != 0,
                   !clones.insert(LinkKey(device: e.device, id: e.cloneID)).inserted {
                    flags.insert(.cloneExtra)
                    size = 0
                }
                bytes += size
                builder.add(parent: ref.node, name: e.name, size: size, flags: flags,
                            inode: e.inode, device: e.device)
            }
        }
    }

    @discardableResult
    private func addDirectory(_ e: RawEntry, in parent: DirRef, flags: NodeFlags) -> NodeID {
        var f = flags.union(.directory)
        if PackageDetector.isPackage(name: e.name) { f.insert(.package) }
        return builder.add(parent: parent.node, name: e.name, size: 0, flags: f,
                           inode: e.inode, device: e.device)
    }

    func path(of ref: DirRef) -> String {
        var names: [String] = []
        var r = ref
        while let parent = r.parent {
            names.append(r.name)
            r = parent
        }
        return names.reversed().reduce(rootPath, join)
    }

    private func join(_ base: String, _ name: String) -> String {
        base == "/" ? "/" + name : base + "/" + name
    }
}

/// Rate limiter for progress callbacks: at most one per 100 ms.
private struct ProgressClock {
    private var last = ContinuousClock.now
    mutating func due() -> Bool {
        let now = ContinuousClock.now
        guard now - last >= .milliseconds(100) else { return false }
        last = now
        return true
    }
}
