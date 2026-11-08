import Darwin
import Foundation

enum FullDiskAccess {
    /// Opens the user's TCC database read-only: only Full Disk Access allows it,
    /// and the refusal (EPERM/EACCES) raises no dialog. Any other failure also
    /// answers false, so TCC-protected folders stay unread.
    static func isGranted(home: String = NSHomeDirectory()) -> Bool {
        let fd = open(home + "/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// The Privacy & Security pane that lists Full Disk Access.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
