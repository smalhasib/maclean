import Foundation
import Testing
@testable import MacleanCore

/// Allocated bytes on disk for `path` (does not follow symlinks).
private func allocSize(_ path: String) throws -> Int64 {
    var st = stat()
    guard lstat(path, &st) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return Int64(st.st_blocks) * 512
}

private func device(_ path: String) -> Int32 {
    var st = stat()
    precondition(stat(path, &st) == 0, "stat \(path)")
    return st.st_dev
}

/// Finds the node at `relative` (slash-separated) below the root.
private func node(_ tree: FileTree, _ relative: String) -> NodeID? {
    var current = tree.root
    for part in relative.split(separator: "/") {
        guard let next = tree.children(of: current).first(where: { tree.name(of: $0) == part }) else { return nil }
        current = next
    }
    return current
}

// Serialized: each scan keeps up to dozens of fds open and many in-flight
// tasks; running them all at once would make fd use depend on test count.
@Suite(.serialized) struct ScannerTests {
    @Test func totalsMatchFixture() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        t.file("a/x", bytes: 8192); t.file("a/b/y", bytes: 4096); t.file("z", bytes: 4096)
        let tree = try await Scanner.scan(path: t.path)
        let expected = try ["a/x", "a/b/y", "z"].map { try allocSize(t.url($0)) }.reduce(0, +)
        #expect(tree.size(of: tree.root) == expected)
        #expect(tree.fileCount(of: tree.root) == 3)
        #expect(tree.rootPath == t.path)
        let b = try #require(node(tree, "a/b"))
        #expect(tree.flags(of: b).contains(.directory))
        #expect(tree.path(of: b) == t.url("a/b"))
        #expect(tree.inode(of: b) != 0)
    }

    @Test func hardLinksCountOnce() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        t.file("one", bytes: 1 << 20); t.dir("sub"); t.hardlink("sub/two", to: "one")
        let tree = try await Scanner.scan(path: t.path)
        #expect(tree.size(of: tree.root) == (try allocSize(t.url("one"))))
        let ids = [try #require(node(tree, "one")), try #require(node(tree, "sub/two"))]
        let first = ids.filter { tree.flags(of: $0).contains(.hardLinkFirst) }
        let extra = ids.filter { tree.flags(of: $0).contains(.hardLinkExtra) }
        #expect(first.count == 1 && extra.count == 1)
        #expect(tree.size(of: extra[0]) == 0)
        #expect(tree.size(of: first[0]) >= 1 << 20)
    }

    @Test func clonesCountOnce() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        t.file("orig", bytes: 1 << 20)
        try #require(clonefile(t.url("orig"), t.url("copy"), 0) == 0, "clonefile unsupported here")
        let h = try DirectoryReader.open(path: t.path)
        let raw = try DirectoryReader.entries(of: h)
        try #require(raw.allSatisfy { $0.cloneRefCount > 0 }, "no clone support (non-APFS)")

        let tree = try await Scanner.scan(path: t.path)
        #expect(tree.size(of: tree.root) == (try allocSize(t.url("orig"))))
        let ids = [try #require(node(tree, "orig")), try #require(node(tree, "copy"))]
        let extra = ids.filter { tree.flags(of: $0).contains(.cloneExtra) }
        #expect(extra.count == 1)
        #expect(tree.size(of: extra[0]) == 0)
    }

    @Test func hardLinkToCloneCountsOnce() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        t.file("orig", bytes: 1 << 20); t.hardlink("link", to: "orig")
        try #require(clonefile(t.url("orig"), t.url("copy"), 0) == 0, "clonefile unsupported here")
        let tree = try await Scanner.scan(path: t.path)
        #expect(tree.size(of: tree.root) == (try allocSize(t.url("orig"))))
    }

    @Test func symlinkLoopIsNotFollowed() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        t.file("f", bytes: 100); t.symlink("loop", to: ".")
        let tree = try await Scanner.scan(path: t.path)
        let loop = try #require(node(tree, "loop"))
        #expect(tree.flags(of: loop).contains(.symlink))
        #expect(!tree.flags(of: loop).contains(.directory))
        #expect(tree.children(of: loop).isEmpty)
        #expect(tree.count == 3)
    }

    @Test func unreadableDirIsRestricted() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        t.file("secret/inside", bytes: 50_000); t.file("open/visible", bytes: 4096)
        t.chmod("secret", 0o000)
        let tree = try await Scanner.scan(path: t.path)
        let secret = try #require(node(tree, "secret"))
        #expect(tree.flags(of: secret).contains(.restricted))
        #expect(tree.flags(of: secret).contains(.directory))
        #expect(tree.size(of: secret) == 0)
        #expect(tree.children(of: secret).isEmpty)
        #expect(tree.fileCount(of: tree.root) == 1)
        #expect(node(tree, "open/visible") != nil)
    }

    @Test func deepNestingBeyondPathMax() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        // Build with openat/mkdirat: the full path exceeds PATH_MAX.
        var fd = open(t.path, O_RDONLY | O_DIRECTORY)
        try #require(fd >= 0)
        for _ in 0..<300 {
            try #require(mkdirat(fd, "d123456789", 0o755) == 0)
            let next = openat(fd, "d123456789", O_RDONLY | O_DIRECTORY)
            close(fd)
            try #require(next >= 0)
            fd = next
        }
        let file = openat(fd, "bottom", O_WRONLY | O_CREAT, 0o644)
        try #require(file >= 0)
        #expect(write(file, "hello", 5) == 5)
        close(file); close(fd)
        defer { Self.removeDeep(t.path) }

        let tree = try await Scanner.scan(path: t.path)
        #expect(tree.fileCount(of: tree.root) == 1)
        #expect(tree.count == 302)
    }

    @Test func deepAndWideExceedsFdBudget() async throws {
        // A sibling at every level keeps each parent's children pending, so
        // more directories want an open fd than the budget allows and the
        // rest must be reopened name by name from an open ancestor.
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        try Self.makeDeepAndWide(t)
        defer { Self.removeDeep(t.path) }

        let tree = try await Scanner.scan(path: t.path)
        #expect(tree.fileCount(of: tree.root) == 300)
        #expect(tree.count == 1 + 300 * 3)
        #expect(!tree.flags(of: tree.root).contains(.restricted))
    }

    @Test func packageIsFlagged() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        t.file("Foo.app/Contents/Info.plist", bytes: 4096); t.dir("plain")
        let tree = try await Scanner.scan(path: t.path)
        let app = try #require(node(tree, "Foo.app"))
        #expect(tree.flags(of: app).isSuperset(of: [.package, .directory]))
        #expect(tree.fileCount(of: app) == 1)
        #expect(node(tree, "Foo.app/Contents/Info.plist") != nil)
        #expect(!tree.flags(of: try #require(node(tree, "plain"))).contains(.package))
    }

    @Test func packageDetector() {
        #expect(PackageDetector.isPackage(name: "Foo.app"))
        #expect(PackageDetector.isPackage(name: "x.BUNDLE"))
        #expect(!PackageDetector.isPackage(name: "notes.txt"))
        #expect(!PackageDetector.isPackage(name: "folder"))
        #expect(!PackageDetector.isPackage(name: ".app"))
    }

    @Test func boundaryForStartupDisk() {
        let b = ScanBoundary.forRoot("/")
        #expect(b.skippedPaths.contains("/System/Volumes/Data"))
        // On some macOS releases the sealed system volume and the Data volume
        // report the same st_dev, so the set may hold one or two devices.
        // Same-container volumes (Preboot, VM, ...) add their own devices.
        let expected: Set<Int32> = [device("/"), device("/System/Volumes/Data")]
        let volumes = Set(b.descendableMounts.map(device))
        #expect(b.allowedDevices == expected.union(volumes))
        #expect((1...2).contains(b.allowedDevices.subtracting(volumes).count))
    }

    @Test(arguments: ["/System", "/System/Volumes", "/System/Volumes/", "//", "/./System/../System"])
    func boundarySkipsDataVolumeInsideRoot(root: String) {
        // Preboot's cryptex grafts are skipped too when Preboot is descendable.
        let skipped = ScanBoundary.forRoot(root).skippedPaths
        #expect(skipped.contains("/System/Volumes/Data"))
        #expect(skipped.isSubset(of: ["/System/Volumes/Data", "/System/Volumes/Preboot/Cryptexes"]))
    }

    @Test func boundaryDoesNotSkipDataVolumeOutsideRoot() {
        #expect(ScanBoundary.forRoot("/System/Library").skippedPaths.isEmpty)
        #expect(ScanBoundary.forRoot("/System/Volumes/Data").skippedPaths.isEmpty)
    }

    @Test func canonicalPathResolvesSlashesDotsAndSymlinks() {
        #expect(ScanBoundary.canonicalPath("//") == "/")
        #expect(ScanBoundary.canonicalPath("/./System/") == "/System")
        #expect(ScanBoundary.canonicalPath("/nonexistent-maclean-\(UUID().uuidString)") == nil)
    }

    @Test func nonCanonicalRootYieldsCanonicalRootPath() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        t.file("real/a", bytes: 4096); t.symlink("link", to: "real")
        let dotted = (t.path as NSString).deletingLastPathComponent + "/./"
            + (t.path as NSString).lastPathComponent + "//real/"
        let viaDots = try await Scanner.scan(path: dotted)
        #expect(viaDots.rootPath == t.url("real"))
        let viaLink = try await Scanner.scan(path: t.url("link"))
        #expect(viaLink.rootPath == t.url("real"))
        #expect(viaLink.fileCount(of: viaLink.root) == 1)
        let explicit = try await Scanner.scan(path: t.url("link"), boundary: ScanBoundary(allowedDevices: []))
        #expect(explicit.rootPath == t.url("real"))
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/System/Volumes/VM")))
    func mountPointIsFlaggedAndNotDescended() async throws {
        // Scans only the VM volume's parent listing; VM itself is not opened.
        // Restrict devices to none so no other subdirectory is descended.
        let tree = try await Scanner.scan(path: "/System/Volumes", boundary: ScanBoundary(allowedDevices: []))
        let vm = try #require(node(tree, "VM"))
        #expect(tree.flags(of: vm).isSuperset(of: [.directory, .mountPoint]))
        #expect(tree.children(of: vm).isEmpty)
        #expect(tree.size(of: vm) == 0)
    }

    @Test func containerParsing() {
        #expect(ScanBoundary.apfsContainer(ofSource: "/dev/disk3s1s1") == "disk3")
        #expect(ScanBoundary.apfsContainer(ofSource: "/dev/disk3s5") == "disk3")
        #expect(ScanBoundary.apfsContainer(ofSource: "/dev/disk12s2") == "disk12")
        #expect(ScanBoundary.apfsContainer(ofSource: "map auto_home") == nil)
        #expect(ScanBoundary.apfsContainer(ofSource: "//user@server/share") == nil)
    }

    @Test func snapshotSourceDetection() {
        #expect(ScanBoundary.isAPFSSnapshot(source: "/dev/disk3s1s1"))
        #expect(ScanBoundary.isAPFSSnapshot(source: "/dev/disk12s4s2"))
        #expect(!ScanBoundary.isAPFSSnapshot(source: "/dev/disk3s5"))
        #expect(!ScanBoundary.isAPFSSnapshot(source: "/dev/disk3"))
        #expect(!ScanBoundary.isAPFSSnapshot(source: "/dev/disk3s1s1s1"))
        #expect(!ScanBoundary.isAPFSSnapshot(source: "/dev/disk3s1sx"))
        #expect(!ScanBoundary.isAPFSSnapshot(source: "map auto_home"))
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/System/Volumes/Preboot")))
    func startupRootDescendsSameContainerVolumes() {
        let b = ScanBoundary.forRoot("/")
        let mounts = ScanBoundary.mounts()
        #expect(b.descendableMounts.contains("/System/Volumes/Preboot"))
        #expect(!b.descendableMounts.contains("/System/Volumes/Data"))
        #expect(b.skippedPaths.contains("/System/Volumes/Data"))
        #expect(b.descendableMounts.allSatisfy { path in mounts.first(where: { $0.path == path })?.fsType == "apfs" })
        #expect(b.descendableMounts.allSatisfy { path in
            mounts.first(where: { $0.path == path }).map { !ScanBoundary.isAPFSSnapshot(source: $0.source) } ?? false
        })
        // Only the root's own container: every descendable mount shares it.
        let rootContainer = mounts.first(where: { $0.path == "/" }).flatMap {
            ScanBoundary.apfsContainer(ofSource: $0.source)
        }
        #expect(b.descendableMounts.allSatisfy { path in
            mounts.first(where: { $0.path == path }).flatMap {
                ScanBoundary.apfsContainer(ofSource: $0.source)
            } == rootContainer
        })
        for path in b.descendableMounts { #expect(b.allowedDevices.contains(device(path))) }
    }

    @Test func tempRootHasNoDescendableMounts() {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        let b = ScanBoundary.forRoot(t.path)
        #expect(b.descendableMounts.isEmpty)
        #expect(!b.skippedPaths.contains("/System/Volumes/Preboot/Cryptexes"))
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/System/Volumes/Preboot")))
    func startupRootSkipsCryptexGrafts() {
        #expect(ScanBoundary.forRoot("/").skippedPaths.contains("/System/Volumes/Preboot/Cryptexes"))
        #expect(ScanBoundary.forRoot("/System").skippedPaths.contains("/System/Volumes/Preboot/Cryptexes"))
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/System/Volumes/Preboot")))
    func mountPointRootScansNormally() async throws {
        let root = "/System/Volumes/Preboot"
        let b = ScanBoundary.forRoot(root)
        #expect(b.allowedDevices.contains(device(root)))
        #expect(b.descendableMounts.isEmpty)
        let tree = try await Scanner.scan(path: root)
        #expect(!tree.flags(of: tree.root).contains(.mountPoint))
        #expect(!tree.children(of: tree.root).isEmpty)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/System/Volumes/VM")))
    func descendableMountIsOpenedAndKeepsFlag() async throws {
        // Allow only VM's device and mark it descendable: VM is read (it holds
        // at least its own listing) yet keeps .mountPoint; Preboot, also a
        // mount point but not descendable, stays closed.
        let vmDevice = device("/System/Volumes/VM")
        let boundary = ScanBoundary(allowedDevices: [vmDevice],
                                    descendableMounts: ["/System/Volumes/VM"])
        let tree = try await Scanner.scan(path: "/System/Volumes", boundary: boundary)
        let vm = try #require(node(tree, "VM"))
        #expect(tree.flags(of: vm).isSuperset(of: [.directory, .mountPoint]))
        #expect(tree.device(of: vm) == vmDevice)
        #expect(!tree.flags(of: vm).contains(.restricted))
        // A closed mount-point node has no children, so this proves VM was read.
        let listing = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Volumes/VM")) ?? []
        try #require(!listing.isEmpty, "VM volume is empty: cannot tell whether it was read")
        #expect(!tree.children(of: vm).isEmpty)
        if let preboot = node(tree, "Preboot") {
            #expect(tree.flags(of: preboot).contains(.mountPoint))
            #expect(tree.children(of: preboot).isEmpty)
        }
    }

    @Test func boundaryForOrdinaryRoot() {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        let b = ScanBoundary.forRoot(t.path)
        #expect(b.allowedDevices == [device(t.path)])
        #expect(b.skippedPaths.isEmpty)
    }

    @Test func otherDeviceIsNotDescended() async throws {
        // Mount points can't be created in a temp dir, so allow no device at
        // all: every subdirectory then counts as foreign (the root is exempt).
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        t.file("top", bytes: 4096); t.file("mnt/inner", bytes: 4096); t.dir("Other.app/x")
        let tree = try await Scanner.scan(path: t.path, boundary: ScanBoundary(allowedDevices: []))
        let mnt = try #require(node(tree, "mnt"))
        #expect(tree.flags(of: mnt).contains(.directory))
        #expect(!tree.flags(of: mnt).contains(.restricted))
        #expect(tree.children(of: mnt).isEmpty)
        #expect(tree.size(of: mnt) == 0)
        #expect(tree.device(of: mnt) == device(t.url("mnt")))
        #expect(tree.flags(of: try #require(node(tree, "Other.app"))).contains(.package))
        #expect(tree.fileCount(of: tree.root) == 1)
    }

    @Test func skippedPathIsNotDescended() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        t.file("keep/a", bytes: 4096); t.file("skip/b", bytes: 4096)
        let boundary = ScanBoundary(allowedDevices: [device(t.path)], skippedPaths: [t.url("skip")])
        let tree = try await Scanner.scan(path: t.path, boundary: boundary)
        let skip = try #require(node(tree, "skip"))
        #expect(tree.flags(of: skip).contains(.directory))
        #expect(tree.children(of: skip).isEmpty)
        #expect(tree.fileCount(of: tree.root) == 1)
    }

    @Test func missingRootThrows() async {
        await #expect(throws: ReadError.notFound) {
            _ = try await Scanner.scan(path: "/nonexistent-maclean-\(UUID().uuidString)")
        }
    }

    @Test func progressIsReported() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        for i in 0..<200 { t.file("d\(i)/f", bytes: 4096) }
        let calls = Counter()
        let tree = try await Scanner.scan(path: t.path) { p in
            calls.record(p)
        }
        #expect(tree.fileCount(of: tree.root) == 200)
        #expect(calls.last.map { $0.items <= 400 && $0.bytes >= 0 } ?? true)
    }

    @Test func cancellationThrows() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        for i in 0..<2_000 { t.dir("d\(i / 50)/e\(i)") }
        let path = t.path
        let task = Task { try await Scanner.scan(path: path) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func concurrentScansShareSmallBudget() async throws {
        let budget = FDBudget(limit: 24)
        let a = TempDir(); try Self.makeDeepAndWide(a)
        let b = TempDir(); try Self.makeDeepAndWide(b)
        defer { Self.removeDeep(a.path); Self.removeDeep(b.path); withExtendedLifetime((a, b)) {} }
        let (pa, pb) = (a.path, b.path)
        async let ta = Scanner.scan(path: pa, boundary: .forRoot(pa), budget: budget, progress: { _ in })
        async let tb = Scanner.scan(path: pb, boundary: .forRoot(pb), budget: budget, progress: { _ in })
        let (x, y) = try await (ta, tb)
        #expect(restrictedCount(x) == 0 && restrictedCount(y) == 0)
        #expect(x.fileCount(of: x.root) == 300)
        #expect(x.fileCount(of: x.root) == y.fileCount(of: y.root))
        #expect(budget.highWater <= 24 + 8)  // floor overshoot allowed for the second scan
    }

    @Test func budgetIsReleasedAfterCancel() async throws {
        let t = TempDir(); defer { withExtendedLifetime(t) {} }
        for i in 0..<2_000 { t.dir("d\(i / 50)/e\(i)") }
        let (inFlight, retained) = (Scanner.desiredInFlight, Scanner.desiredRetained)
        let budget = FDBudget(limit: 2 * inFlight + retained)
        let path = t.path
        let task = Task {
            try await Scanner.scan(path: path, boundary: .forRoot(path), budget: budget) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(budget.highWater > 0)  // the scan did acquire a grant before cancelling
        let grant = budget.acquire(desiredInFlight: inFlight, desiredRetained: retained)
        #expect(grant.inFlight == inFlight && grant.retained == retained)
    }

    @Test func budgetGrantsScaleDownToFloor() {
        let budget = FDBudget(limit: 100)
        let full = budget.acquire(desiredInFlight: 10, desiredRetained: 40)  // costs 60
        #expect(full.inFlight == 10 && full.retained == 40)
        let scaled = budget.acquire(desiredInFlight: 10, desiredRetained: 40)  // 40 left
        #expect(scaled.inFlight < 10 && scaled.retained < 40)
        #expect(2 * scaled.inFlight + scaled.retained <= 40)
        let floor = budget.acquire(desiredInFlight: 10, desiredRetained: 40)  // nothing left
        #expect(floor.inFlight == 2 && floor.retained == 4)
        #expect(budget.highWater == 60 + 2 * scaled.inFlight + scaled.retained + 8)
        for g in [full, scaled, floor] { budget.release(g) }
        let again = budget.acquire(desiredInFlight: 10, desiredRetained: 40)
        #expect(again.inFlight == 10 && again.retained == 40)
    }

    private func restrictedCount(_ tree: FileTree) -> Int {
        (0..<tree.count).filter { tree.flags(of: NodeID(index: Int32($0))).contains(.restricted) }.count
    }

    /// 300 nested `d123456789` levels, each with a sibling `s/f`: a sibling at
    /// every level keeps each parent's children pending, so more directories
    /// want an open fd than the budget allows. Remove with `removeDeep`.
    private static func makeDeepAndWide(_ t: TempDir) throws {
        var fd = open(t.path, O_RDONLY | O_DIRECTORY)
        try #require(fd >= 0)
        for _ in 0..<300 {
            try #require(mkdirat(fd, "s", 0o755) == 0)
            let f = openat(fd, "s/f", O_WRONLY | O_CREAT, 0o644)
            try #require(f >= 0); close(f)
            try #require(mkdirat(fd, "d123456789", 0o755) == 0)
            let next = openat(fd, "d123456789", O_RDONLY | O_DIRECTORY)
            close(fd)
            try #require(next >= 0)
            fd = next
        }
        close(fd)
    }

    /// Removes a tree deeper than PATH_MAX (FileManager cannot).
    private static func removeDeep(_ root: String) {
        func purge(_ parent: Int32, _ name: String) {
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if fd >= 0 {
                let h = DirectoryHandle(fd: dup(fd))
                for e in (try? DirectoryReader.entries(of: h)) ?? [] {
                    if e.kind == .directory { purge(fd, e.name) } else { unlinkat(fd, e.name, 0) }
                }
                close(fd)
            }
            unlinkat(parent, name, AT_REMOVEDIR)
        }
        let fd = open(root, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { return }
        purge(fd, "d123456789")
        close(fd)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ScanProgress] = []
    func record(_ p: ScanProgress) { lock.withLock { values.append(p) } }
    var last: ScanProgress? { lock.withLock { values.last } }
}
