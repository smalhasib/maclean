import AppKit
import MacleanCore
import MacleanKit

/// The Smart Clean card's, alert's and skipped list's words, kept pure so they can be tested.
enum SmartCleanCopy {
    static let nothing = "Nothing to clean right now"
    static let checking = "Checking for cleanable items…"
    static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// The cleanable total (Info rows excluded), as the card shows it in bold.
    static func cardSize(_ report: CleanReport) -> String? {
        let total = report.candidates.filter { $0.tier != .info }.reduce(Int64(0)) { $0 + ($1.measurement?.size ?? 0) }
        return total > 0 ? SizeText.string(total) : nil
    }

    /// "18.6 GB can be cleaned"; with items but no cleanable size (all Info or size unknown),
    /// "Nothing to clean automatically — review 3 items"; else "Nothing to clean right now".
    static func cardLine(_ report: CleanReport) -> String {
        if let size = cardSize(report) { return "\(size) can be cleaned" }
        let n = report.candidates.count
        return n == 0 ? nothing : "Nothing to clean automatically — review \(n) \(n == 1 ? "item" : "items")"
    }

    /// The names of the three biggest categories, biggest first ("App caches, Logs, Developer files").
    static func breakdown(_ report: CleanReport) -> String {
        var sizes: [CleanRule.Category: Int64] = [:]
        for c in report.candidates where c.tier != .info { sizes[c.category, default: 0] += c.measurement?.size ?? 0 }
        let order = CleanRule.Category.allCases
        return sizes.filter { $0.value > 0 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : order.firstIndex(of: $0.key)! < order.firstIndex(of: $1.key)! }
            .prefix(3).map { name($0.key) }.joined(separator: ", ")
    }

    static func name(_ category: CleanRule.Category) -> String {
        switch category {
        case .appCaches: "App caches"
        case .browsers: "Browser caches"
        case .logs: "Logs"
        case .developer: "Developer files"
        case .projectLeftovers: "Project leftovers"
        case .oldInstallers: "Old installers"
        case .removedApps: "Leftovers of removed apps"
        case .windowState: "Saved window state"
        case .trash: "Trash"
        case .mailAttachments: "Mail attachments"
        case .systemLogs: "System logs"
        case .systemCaches: "System caches"
        case .systemServices: "System services"
        case .largeData: "Large data"
        }
    }

    /// The confirmation alert before Clean.
    /// `includesTrash`: the selection holds Trash items, which are always deleted permanently.
    /// `needsAdmin` in Trash mode: system items can't be moved to the Trash, so no
    /// password is promised; they are skipped (R30).
    static func alert(count: Int, size: Int64, mode: DeleteMode, needsAdmin: Bool,
                      includesTrash: Bool = false) -> (title: String, message: String) {
        var message = mode == .trash ? "They will be moved to the Trash." : "They will be deleted permanently."
        if mode == .trash, includesTrash { message += " Items already in the Trash will be deleted permanently." }
        if needsAdmin {
            message += mode == .trash ? " System items can't be moved to the Trash and will be skipped."
                : " Some items need your administrator password."
        }
        return ("Delete \(count) \(count == 1 ? "item" : "items") (\(SizeText.string(size)))?", message)
    }

    /// Why an item was found but not offered, in plain words.
    static func skipReason(_ r: SkipReason) -> String {
        switch r {
        case .appRunning(let owner): "\(SmartCleanController.appName(owner)) is open"
        case .inUse: "In use by a running process"
        case .ownerUnknown: "Can't tell which app it belongs to"
        case .recent: "Used recently"
        case .protected(let refusal): protectedReason(refusal)
        case .noAccess: "Needs Full Disk Access"
        case .neverClean: "On your never-clean list"
        case .macOSSystemCache: "A macOS system cache"
        case .installedCheckFailed: "Couldn't check which apps are installed"
        case .containsGit: "Contains a Git repository"
        case .gitTracked: "Tracked by Git"
        case .projectInUse: "The project is in use"
        case .locallyPatched: "Has local changes"
        case .sameOSInstaller: "Installer for the macOS you're running"
        case .categoryOff: "Turned off in Settings"
        }
    }

    private static func protectedReason(_ r: Refusal) -> String {
        switch r {
        case .systemProtected: "Protected by macOS"
        case .volumeRoot: "A whole disk"
        case .libraryItself, .criticalRoot: "An important folder"
        case .homeItself: "Your home folder"
        case .macleanItself: "Maclean itself"
        case .timeMachine: "On a Time Machine backup"
        case .unsafePath: "Can't be deleted safely"
        case .personalData: "Holds personal data"
        case .neverClean: "On your never-clean list"
        case .protectedApp: "Belongs to a protected app (security, passwords or network)"
        case .appleSystem: "A macOS system cache"
        }
    }

    /// "last used 3 months ago".
    static func lastUsed(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "last used \(formatter.localizedString(for: date, relativeTo: now))"
    }
}

enum CategoryState {
    /// A section checkbox's state over its selectable `paths`.
    static func tri(_ paths: [String], selected: Set<String>) -> NSControl.StateValue {
        let n = paths.filter(selected.contains).count
        return n == 0 ? .off : n == paths.count ? .on : .mixed
    }
}
