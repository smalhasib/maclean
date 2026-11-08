import Darwin
import Foundation

enum FullDiskAccess {
    /// True when any of `probes` can be opened read-only. Each one is readable
    /// only with Full Disk Access, and a refusal (EPERM/EACCES) raises no
    /// dialog. A missing probe decides nothing: macOS 27 has no per-user
    /// `com.apple.TCC` folder, which made the old single-file check always fail.
    static func isGranted(home: String = NSHomeDirectory()) -> Bool {
        isGranted(probes: defaultProbes(home: home))
    }

    static func isGranted(probes: [String]) -> Bool {
        probes.contains { path in
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return false }
            close(fd)
            return true
        }
    }

    /// Locations macOS protects with Full Disk Access and no consent dialog.
    /// The system TCC database exists on every Mac; the rest cover systems
    /// where it moves. Never Desktop, Documents or Downloads: those prompt.
    static func defaultProbes(home: String) -> [String] {
        [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Safari",
            home + "/Library/Mail",
            home + "/Library/Messages",
        ]
    }

    /// The Privacy & Security pane that lists Full Disk Access.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
