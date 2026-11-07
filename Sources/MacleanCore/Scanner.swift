import Darwin
import Foundation
import os

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
/// Directory reads run concurrently in a task group; each child hands its
/// blocking read (openat chain, fstat, getattrlistbulk) to a private
/// concurrent dispatch queue so Swift's cooperative pool never blocks. A
/// single consumer — the scanning task itself — appends results to the
/// non-thread-safe `FileTreeBuilder` and schedules child directories
/// depth-first. Reads in flight and directories keeping an fd open are
/// bounded by a grant from the process-wide `FDBudget`.
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
    /// `.mountPoint` nodes and never opened, unless their path is in
    /// `boundary.descendableMounts`: those are read like any directory and
    /// keep `.mountPoint`. The root is never treated as a mount point. Only a
    /// root that cannot be resolved or opened throws (a `ReadError`); unreadable subdirectories
    /// become `.restricted` nodes. Throws `CancellationError` when the calling
    /// task is cancelled.
    public static func scan(path: String, boundary: ScanBoundary,
                            progress: @Sendable (ScanProgress) -> Void = { _ in }) async throws -> FileTree {
        try await scan(path: path, boundary: boundary, budget: .shared, progress: progress)
    }

    /// Reads in flight a scan asks its budget for.
    static let desiredInFlight = ProcessInfo.processInfo.activeProcessorCount * 2
    /// Directories (besides the root) a scan asks to keep open.
    static let desiredRetained = 128

    /// `scan(path:boundary:progress:)` drawing its fd allowance from `budget`;
    /// the grant is returned when the scan ends (success, throw or cancel).
    static func scan(path: String, boundary: ScanBoundary, budget: FDBudget,
                     progress: @Sendable (ScanProgress) -> Void) async throws -> FileTree {
        try Task.checkCancellation()
        let rootPath = try canonicalRoot(path)
        let rootHandle = try DirectoryReader.open(path: rootPath)
        var st = stat()
        let ok = fstat(rootHandle.fd, &st) == 0
        let rootInode = ok ? UInt64(st.st_ino) : 0
        let rootDevice = ok ? st.st_dev : 0

        let grant = budget.acquire(desiredInFlight: desiredInFlight, desiredRetained: desiredRetained)
        defer { budget.release(grant) }
        let cancel = CancelFlag()

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: (Int, Outcome).self) { group in
                // On any exit, reads still queued return at once instead of
                // making the group's implicit drain wait for them.
                defer { cancel.set() }
                var walk = Walk(rootPath: rootPath, rootInode: rootInode, rootDevice: rootDevice,
                                rootHandle: rootHandle, boundary: boundary, grant: grant)
                let allowed = boundary.allowedDevices
                var clock = ProgressClock()

                group.addTask {
                    (Walk.rootToken, await readOffPool(anchor: rootHandle, path: [], allowed: nil, cancel: cancel))
                }
                var inFlight = 1

                while let (token, outcome) = try await group.next() {
                    inFlight -= 1
                    if Task.isCancelled { throw CancellationError() }
                    if let current = walk.handle(token: token, outcome: outcome), clock.due() {
                        progress(ScanProgress(bytes: walk.bytes, items: walk.items,
                                              currentPath: walk.path(of: current)))
                    }
                    while inFlight < walk.maxInFlight, let job = walk.nextJob() {
                        group.addTask {
                            (job.token, await readOffPool(anchor: job.anchor, path: job.path,
                                                          allowed: allowed, cancel: cancel))
                        }
                        inFlight += 1
                    }
                }
                return walk.builder.finish()
            }
        } onCancel: {
            cancel.set()
        }
    }

    // MARK: - Job (runs concurrently)

    enum Outcome: Sendable {
        case listed(DirectoryHandle, inode: UInt64, device: Int32, [RawEntry])
        case otherDevice(inode: UInt64, device: Int32)
        case failed(ReadError)
    }

    /// Blocking reads run here rather than on the cooperative pool. In-flight
    /// reads are bounded by the scan's fd grant, so GCD cannot over-spawn.
    private static let ioQueue = DispatchQueue(label: "maclean.scan.io", qos: .utility,
                                               attributes: .concurrent)

    /// Runs `read` on `ioQueue`. The continuation is resumed exactly once by
    /// the queued closure, which returns at once if `cancel` is set by then.
    static func readOffPool(anchor: DirectoryHandle, path: [String], allowed: Set<Int32>?,
                            cancel: CancelFlag) async -> Outcome {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                continuation.resume(returning: read(anchor: anchor, path: path, allowed: allowed, cancel: cancel))
            }
        }
    }

    /// Opens `path` (names relative to `anchor`, never following symlinks),
    /// checks its device against `allowed` (nil: no check) and lists it.
    /// Returns `ECANCELED` without touching the disk once `cancel` is set
    /// (a GCD thread has no current task, so `Task.isCancelled` can't be used).
    static func read(anchor: DirectoryHandle, path: [String], allowed: Set<Int32>?,
                     cancel: CancelFlag) -> Outcome {
        if cancel.isSet { return .failed(.other(ECANCELED)) }
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

/// A one-way flag set when a scan is cancelled or ends, checked by reads
/// queued on the I/O queue.
final class CancelFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    func set() { state.withLock { $0 = true } }
    var isSet: Bool { state.withLock { $0 } }
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
    /// Flags its node gets once read (`.mountPoint` for a descendable mount).
    var flags: NodeFlags = []
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
    /// Deepest skipped path or descendable mount, in components below the
    /// root (paths are only built for directories this shallow).
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
         boundary: ScanBoundary, grant: FDBudget.Grant) {
        builder = FileTreeBuilder(rootPath: rootPath, rootInode: rootInode, rootDevice: rootDevice)
        self.rootPath = rootPath
        self.boundary = boundary
        rootRef = DirRef(parent: nil, name: rootPath, node: builder.root, depth: 0, handle: rootHandle)

        maxInFlight = grant.inFlight
        maxRetained = grant.retained

        let rootComponents = rootPath.split(separator: "/").count
        maxSkipDepth = boundary.skippedPaths.union(boundary.descendableMounts)
            .map { $0.split(separator: "/").count - rootComponents }
            .max() ?? 0
    }

    /// Records a finished job. Returns the directory when it was read.
    mutating func handle(token: Int, outcome: Scanner.Outcome) -> DirRef? {
        let parent: DirRef?
        let entry: RawEntry?
        var flags: NodeFlags = []
        if token == Self.rootToken {
            (parent, entry) = (nil, nil)
        } else {
            let pending = inFlight.removeValue(forKey: token)!
            (parent, entry, flags) = (pending.parent, pending.entry, pending.flags)
        }

        switch outcome {
        case .failed(.notFound):
            return nil  // vanished since its parent was listed
        case .failed:
            if let parent, let entry {
                addDirectory(entry, in: parent, flags: flags.union(.restricted))
            } else {
                builder.markRestricted(builder.root)
            }
            return nil
        case let .otherDevice(inode, device):
            if let parent, let entry {
                var e = entry
                (e.inode, e.device) = (inode, device)
                addDirectory(e, in: parent, flags: flags)
            }
            return nil
        case let .listed(handle, inode, device, entries):
            let ref: DirRef
            if let parent, let entry {
                var e = entry
                (e.inode, e.device) = (inode, device)
                let node = addDirectory(e, in: parent, flags: flags)
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
                // Mount points are only opened when the boundary lists them
                // (same-container APFS volumes): crossing into another volume
                // could trigger an automount or hang on a stale network mount.
                if e.isMountPoint {
                    if checkSkips, boundary.descendableMounts.contains(join(base, e.name)) {
                        stack.append(Pending(parent: ref, entry: e, flags: .mountPoint))
                        ref.undispatched += 1
                    } else {
                        addDirectory(e, in: ref, flags: .mountPoint)
                    }
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

/// Rate limiter for progress callbacks: the first is due at once (after the
/// root is read), then at most one per 100 ms.
private struct ProgressClock {
    private var last: ContinuousClock.Instant?
    mutating func due() -> Bool {
        let now = ContinuousClock.now
        if let last, now - last < .milliseconds(100) { return false }
        last = now
        return true
    }
}
