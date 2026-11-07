import Darwin

/// Which directories a scan may descend into.
///
/// Directories whose device is not in `allowedDevices`, or whose absolute path
/// is in `skippedPaths`, are recorded as empty directory nodes and not read.
/// `skippedPaths` are compared against canonical (`realpath`) paths, since
/// the scanner canonicalizes its root.
public struct ScanBoundary: Sendable {
    public var allowedDevices: Set<Int32>
    public var skippedPaths: Set<String>

    public init(allowedDevices: Set<Int32>, skippedPaths: Set<String> = []) {
        self.allowedDevices = allowedDevices
        self.skippedPaths = skippedPaths
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
        return boundary
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
