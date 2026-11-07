import Darwin

/// Which directories a scan may descend into.
///
/// Directories whose device is not in `allowedDevices`, or whose absolute path
/// is in `skippedPaths`, are recorded as empty directory nodes and not read.
/// Mount points are never opened unless their path is in `descendableMounts`.
/// Paths are compared against canonical (`realpath`) paths, since the
/// scanner canonicalizes its root.
public struct ScanBoundary: Sendable {
    public var allowedDevices: Set<Int32>
    public var skippedPaths: Set<String>
    /// Canonical paths of mount points the scan may enter.
    public var descendableMounts: Set<String>

    public init(allowedDevices: Set<Int32>, skippedPaths: Set<String> = [],
                descendableMounts: Set<String> = []) {
        self.allowedDevices = allowedDevices
        self.skippedPaths = skippedPaths
        self.descendableMounts = descendableMounts
    }

    static let dataVolume = "/System/Volumes/Data"
    static let prebootVolume = "/System/Volumes/Preboot"
    /// Cryptex graft points (OS, App, Rosetta, ...): their contents are the
    /// disk images under Preboot's `<UUID>/cryptex1`, already counted there.
    static let prebootCryptexes = "/System/Volumes/Preboot/Cryptexes"
    /// Canonical roots that contain the startup disk's Data volume mount point.
    static let rootsContainingDataVolume: Set<String> = ["/", "/System", "/System/Volumes"]

    /// The boundary for scanning `path` (canonicalized with `realpath`): its
    /// own device only. A root on the sealed system volume (the device of
    /// `/`) also allows the Data volume's device, so firmlinked folders
    /// (`/Users`, `/Applications`, ...) are followed. Whenever the Data
    /// volume's mount point lies inside the root it is skipped, so those
    /// folders are scanned once, through their firmlinked paths. (On recent
    /// macOS the system and Data volumes share one `st_dev`, so the device
    /// check alone cannot stop the scan from entering the Data volume.)
    ///
    /// When the root lies on an APFS volume, the other mounted volumes of the
    /// same APFS container whose mount points lie strictly inside the root
    /// (Preboot, VM, Update, Recovery for `/`) are made descendable, as
    /// DaisyDisk counts them; the Data volume is excluded (see above). Whenever
    /// Preboot's `Cryptexes` graft directory lies strictly inside the root
    /// (the root is Preboot or contains it), it is skipped.
    public static func forRoot(_ path: String) -> ScanBoundary {
        forRoot(path, mounts: mounts())
    }

    /// `forRoot(_:)` against an explicit mount list (the seam for tests and
    /// callers that already hold a snapshot of the mount table).
    public static func forRoot(_ path: String, mounts: [MountInfo]) -> ScanBoundary {
        let root = canonicalPath(path) ?? path
        var boundary = ScanBoundary(allowedDevices: [])
        let rootDevice = device(of: root)
        if let rootDevice { boundary.allowedDevices.insert(rootDevice) }
        if let rootDevice, rootDevice == device(of: "/"), let data = device(of: dataVolume) {
            boundary.allowedDevices.insert(data)
        }
        if rootsContainingDataVolume.contains(root) {
            boundary.skippedPaths.insert(dataVolume)
        }
        if let own = mounts.filter({ isInside($0.path, orEqualTo: root) })
                .max(by: { $0.path.count < $1.path.count }),
           own.fsType == "apfs", let container = apfsContainer(ofSource: own.source) {
            // Snapshot mounts (e.g. a staged update's, under Update) show
            // bytes their volume already holds; the root's own mount may be a
            // snapshot (`/`), so only candidates are filtered.
            for m in mounts where m.fsType == "apfs" && m.path != root && m.path != dataVolume
                && !isAPFSSnapshot(source: m.source)
                && isInside(root, orEqualTo: m.path)
                && apfsContainer(ofSource: m.source) == container {
                boundary.descendableMounts.insert(m.path)
                boundary.allowedDevices.insert(m.device)
            }
        }
        if root != prebootCryptexes && isInside(root, orEqualTo: prebootCryptexes) {
            boundary.skippedPaths.insert(prebootCryptexes)
        }
        return boundary
    }

    /// Whether `path` is `ancestor` or lies below it (component-wise).
    private static func isInside(_ ancestor: String, orEqualTo path: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor == "/" ? "/" : ancestor + "/")
    }

    /// Absolute path with symlinks, `.`, `..` and duplicate slashes resolved
    /// (`realpath(3)`), or nil when it cannot be resolved.
    public static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `stat` (following symlinks, as the scan root is followed) device id.
    private static func device(of path: String) -> Int32? {
        var st = stat()
        return stat(path, &st) == 0 ? st.st_dev : nil
    }
}

public struct MountInfo: Sendable, Equatable {
    public let path: String
    public let device: Int32
    public let source: String
    public let fsType: String

    public init(path: String, device: Int32, source: String, fsType: String) {
        self.path = path
        self.device = device
        self.source = source
        self.fsType = fsType
    }
}

extension ScanBoundary {
    /// Currently mounted file systems (`getmntinfo(MNT_NOWAIT)`: cached
    /// statistics, so a stale network mount cannot block).
    public static func mounts() -> [MountInfo] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = Int(getmntinfo(&buffer, MNT_NOWAIT))
        guard count > 0, let buffer else { return [] }
        return (0..<count).map { i in
            var fs = buffer[i]
            func string<T>(_ field: inout T) -> String {
                withUnsafeBytes(of: &field) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            }
            return MountInfo(path: string(&fs.f_mntonname), device: fs.f_fsid.val.0,
                             source: string(&fs.f_mntfromname), fsType: string(&fs.f_fstypename))
        }
    }

    /// The APFS container of a volume's device node: `/dev/disk3s1s1` (a
    /// volume, or a snapshot of one) gives `disk3`; anything else gives nil.
    static func apfsContainer(ofSource source: String) -> String? {
        guard source.hasPrefix("/dev/disk") else { return nil }
        let rest = source.dropFirst("/dev/disk".count)
        let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        let after = rest.dropFirst(digits.count)
        guard !digits.isEmpty, after.first == "s",
              after.dropFirst().first.map({ $0.isASCII && $0.isNumber }) == true else { return nil }
        return "disk" + digits
    }

    /// Whether a device node names an APFS snapshot (`/dev/disk3s1s1`)
    /// rather than a volume (`/dev/disk3s5`).
    static func isAPFSSnapshot(source: String) -> Bool {
        guard source.hasPrefix("/dev/disk") else { return false }
        var rest = Substring(source.dropFirst("/dev/disk".count))
        var numbers = 0
        while true {
            let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
            guard !digits.isEmpty else { return false }
            numbers += 1
            rest = rest.dropFirst(digits.count)
            if rest.isEmpty { return numbers == 3 }
            guard rest.first == "s" else { return false }
            rest = rest.dropFirst()
        }
    }
}
