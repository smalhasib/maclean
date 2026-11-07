import Darwin

/// Which directories a scan may descend into.
///
/// Directories whose device is not in `allowedDevices`, or whose absolute path
/// is in `skippedPaths`, are recorded as empty directory nodes and not read.
public struct ScanBoundary: Sendable {
    public var allowedDevices: Set<Int32>
    public var skippedPaths: Set<String>

    public init(allowedDevices: Set<Int32>, skippedPaths: Set<String> = []) {
        self.allowedDevices = allowedDevices
        self.skippedPaths = skippedPaths
    }

    static let dataVolume = "/System/Volumes/Data"

    /// The boundary for scanning `path`: its own device only. For the startup
    /// disk (`/`) the Data volume's device is allowed too, and the Data
    /// volume's mount point is skipped, so firmlinked folders (`/Users`,
    /// `/Applications`, ...) are scanned once, through their `/` paths.
    public static func forRoot(_ path: String) -> ScanBoundary {
        var boundary = ScanBoundary(allowedDevices: [])
        if let dev = device(of: path) { boundary.allowedDevices.insert(dev) }
        if path == "/" {
            if let dev = device(of: dataVolume) { boundary.allowedDevices.insert(dev) }
            boundary.skippedPaths.insert(dataVolume)
        }
        return boundary
    }

    /// `stat` (following symlinks, as the scan root is followed) device id.
    private static func device(of path: String) -> Int32? {
        var st = stat()
        return stat(path, &st) == 0 ? st.st_dev : nil
    }
}
