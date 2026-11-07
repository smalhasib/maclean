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
    /// DaisyDisk counts them; the Data volume is excluded (see above).
    public static func forRoot(_ path: String) -> ScanBoundary {
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
        let mounts = mounts()
        if let own = mounts.filter({ isInside($0.path, orEqualTo: root) })
                .max(by: { $0.path.count < $1.path.count }),
           own.fsType == "apfs", let container = apfsContainer(ofSource: own.source) {
            for m in mounts where m.fsType == "apfs" && m.path != root && m.path != dataVolume
                && isInside(root, orEqualTo: m.path)
                && apfsContainer(ofSource: m.source) == container {
                boundary.descendableMounts.insert(m.path)
                boundary.allowedDevices.insert(m.device)
            }
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

struct MountInfo: Sendable {
    let path: String
    let device: Int32
    let source: String
    let fsType: String
}

extension ScanBoundary {
    /// Currently mounted file systems (`getmntinfo(MNT_NOWAIT)`: cached
    /// statistics, so a stale network mount cannot block).
    static func mounts() -> [MountInfo] {
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
              after.dropFirst().first?.isNumber == true else { return nil }
        return "disk" + digits
    }
}
