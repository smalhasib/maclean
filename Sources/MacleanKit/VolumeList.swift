import Foundation
import MacleanCore

public struct VolumeEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let scanPath: String
    public let isNetwork: Bool
    public let isDiskImage: Bool

    public init(id: String, name: String, scanPath: String, isNetwork: Bool, isDiskImage: Bool) {
        self.id = id
        self.name = name
        self.scanPath = scanPath
        self.isNetwork = isNetwork
        self.isDiskImage = isDiskImage
    }
}

public enum VolumeList {
    private static let networkTypes: Set<String> = ["smbfs", "afpfs", "nfs", "webdav"]

    /// Filters mounts to what the start screen lists (spec §5.1): the startup
    /// disk, internal/external disks, mounted disk images and network shares.
    /// Hides `/System/Volumes/*`, Recovery, autofs placeholders, devfs and
    /// Time Machine volumes/snapshots. `isDiskImage` is always false: telling
    /// disk images apart needs DiskArbitration, which this Foundation-only
    /// module avoids.
    public static func entries(from mounts: [MountInfo], volumeName: (String) -> String) -> [VolumeEntry] {
        mounts.compactMap { mount in
            guard isListed(mount) else { return nil }
            let path = mount.path
            return VolumeEntry(id: path, name: volumeName(path), scanPath: path,
                               isNetwork: networkTypes.contains(mount.fsType), isDiskImage: false)
        }
    }

    private static func isListed(_ m: MountInfo) -> Bool {
        if m.path == "/" { return true }
        if m.fsType == "autofs" || m.fsType == "devfs" || m.source.hasPrefix("map ") { return false }
        if m.path == "/System/Volumes" || m.path.hasPrefix("/System/Volumes/") { return false }
        if m.path == "/Volumes/Recovery" || m.path.hasPrefix("/Volumes/Recovery/") { return false }
        if m.path.hasPrefix("/Volumes/.timemachine") { return false }
        if m.path.contains("com.apple.TimeMachine") || m.source.contains("com.apple.TimeMachine") { return false }
        return m.path.hasPrefix("/Volumes/") || networkTypes.contains(m.fsType)
    }
}

public struct Capacity: Sendable, Equatable {
    public let total: Int64
    public let freeIncludingPurgeable: Int64

    public init(total: Int64, freeIncludingPurgeable: Int64) {
        self.total = total
        self.freeIncludingPurgeable = freeIncludingPurgeable
    }
}

public enum VolumeCapacity {
    /// Total and free (counting purgeable space) capacity of the volume
    /// containing `path`; nil if it cannot be read.
    public static func of(path: String) -> Capacity? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let total = v.volumeTotalCapacity,
              let free = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return Capacity(total: Int64(total), freeIncludingPurgeable: free)
    }
}
