import Foundation

/// What the banner over a result says about folders that couldn't be read.
///
/// Whether Full Disk Access can help depends on the *scan*, not on the app now: a scan
/// that ran with access already got everything access can open. What macOS still blocks
/// then (system data under `/Library`, `/private/var/db`, …) stays blocked, so asking for a
/// relaunch would only bring the same banner back.
enum RestrictedNotice: Equatable {
    case none
    /// Folders an administrator can open, before the password read (or after a cancelled one).
    case readWithAdmin(count: Int)
    /// The scan ran without access and it isn't on.
    case grantAccess(count: Int)
    /// The scan ran without access, and it is on now: a new process picks it up.
    case relaunch
    /// The scan had access, and macOS still keeps these closed.
    case protectedByMacOS(count: Int)

    /// - adminReadable: restricted folders root can open (not yet read, or read and refused).
    /// - stillNeedsAccess: after a root read, how many root couldn't open; nil before one.
    /// - privacy: folders macOS privacy protection refused (never sent to root).
    static func make(adminReadable: Int, stillNeedsAccess: Int?, privacy: Int,
                     scannedWithAccess: Bool, accessNow: Bool) -> RestrictedNotice {
        if adminReadable > 0, stillNeedsAccess == nil { return .readWithAdmin(count: adminReadable) }
        let blocked = privacy + (stillNeedsAccess ?? 0)
        guard blocked > 0 else { return .none }
        if scannedWithAccess { return .protectedByMacOS(count: blocked) }
        return accessNow ? .relaunch : .grantAccess(count: blocked)
    }
}
