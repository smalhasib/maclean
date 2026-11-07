import Foundation
import Testing
import MacleanCore
@testable import MacleanKit

@Suite struct VolumeListTests {
    private func m(_ path: String, _ source: String = "/dev/disk9s1", _ fs: String = "apfs") -> MountInfo {
        MountInfo(path: path, device: 1, source: source, fsType: fs)
    }

    private var mounts: [MountInfo] {
        [m("/", "/dev/disk3s1s1"), m("/dev", "devfs", "devfs"),
         m("/System/Volumes/Data"), m("/System/Volumes/Preboot"), m("/System/Volumes/VM"),
         m("/System/Volumes/Data/home", "map auto_home", "autofs"),
         m("/Volumes/Recovery"), m("/Volumes/USB", "/dev/disk4s1", "msdos"),
         m("/Volumes/Share", "//u@h/share", "smbfs"),
         m("/net", "map -hosts", "autofs"),
         m("/Volumes/.timemachine/abc/backup", "//u@h/tm", "smbfs"),
         m("/Volumes/com.apple.TimeMachine.localsnapshots/x", "com.apple.TimeMachine.2024-01-01-000000.local", "apfs")]
    }

    private func name(_ path: String) -> String { path == "/" ? "Macintosh HD" : (path as NSString).lastPathComponent }

    @Test func startupAndExternalListedSystemHidden() {
        let e = VolumeList.entries(from: mounts, volumeName: name)
        #expect(e.map(\.id) == ["/", "/Volumes/Share", "/Volumes/USB"])
        #expect(e[0].name == "Macintosh HD")
        #expect(e[0].scanPath == "/")
        #expect(e[1].isNetwork)
        #expect(!e[2].isNetwork)
        #expect(e[2].scanPath == "/Volumes/USB")
    }

    @Test func startupDiskFirstThenByName() {
        let shuffled = [m("/Volumes/Zed"), m("/Volumes/Alpha"), m("/", "/dev/disk3s1s1")]
        #expect(VolumeList.entries(from: shuffled, volumeName: name).map(\.id) == ["/", "/Volumes/Alpha", "/Volumes/Zed"])
    }

    @Test func ejectedVolumeDisappears() {
        let e = VolumeList.entries(from: mounts.filter { $0.path != "/Volumes/USB" }, volumeName: name)
        #expect(e.map(\.id) == ["/", "/Volumes/Share"])
    }

    @Test func capacityOfRoot() throws {
        let c = try #require(VolumeCapacity.of(path: "/"))
        #expect(c.total > 0)
        #expect(c.freeIncludingPurgeable >= 0)
        #expect(VolumeCapacity.of(path: "/nonexistent-\(UUID().uuidString)") == nil)
    }
}
