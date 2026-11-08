import Foundation

/// One Smart Clean target (spec §6.1): where to look, what to offer and under
/// which conditions. The catalog is a list of these; the engine is generic.
public struct CleanRule: Sendable, Identifiable {
    public enum Category: String, CaseIterable, Sendable, Codable {
        case appCaches, browsers, logs, developer, projectLeftovers, oldInstallers, removedApps,
             windowState, trash, mailAttachments, systemLogs, systemCaches, systemServices, largeData
    }
    /// `.safe` is ticked by default, `.review` is offered unticked, `.info` is shown only.
    public enum Tier: Int, Sendable, Codable, Comparable {
        case info, review, safe
        public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }
    /// What is offered: each pattern match itself, or each (non-hidden) child of it.
    public enum Unit: Sendable { case folder, eachChild }
    /// Who must not be running.
    /// - `childNameIfBundleID`: the item's own name (minus `.savedState`); the rule
    ///   only claims items whose name is a bundle id.
    /// - `containerBundleID`: the component after `Containers`; also checks open files.
    /// - `appSupportFolder`: the component after `Application Support`, resolved by the probes.
    public enum Owner: Sendable { case none, bundleID(String), childNameIfBundleID, containerBundleID, appSupportFolder, processName(String) }
    public enum Special: Sendable { case none, keepNewest(Int), derivedData, removedAppLeftover, projectArtifacts, launchdOrphan, macOSInstaller, downloadsInstaller }

    public let id: String
    public let category: Category
    /// `~/…` or absolute. `*`, `?` and `[…]` glob within one segment; `{a,b}` braces
    /// expand over the whole string. Empty means "not path-based" (project artifacts).
    public let pattern: String
    public let unit: Unit
    /// Newest-first match: the first entry whose `days` ≤ the item's age wins;
    /// none → Skipped `.recent`.
    public let ageTiers: [(days: Int, tier: Tier)]
    public let owner: Owner
    /// Glob names for files-only rows (e.g. `*.log`); nil means any item.
    public let fileFilter: [String]?
    /// Glob names never offered (e.g. `*.incomplete`).
    public let exclude: [String]
    public let requiresAdmin: Bool
    /// `probes.isOpen` must be false (system log files, idleassetsd tmp files).
    public let requireNotOpen: Bool
    public let special: Special
    public let reason: String

    public init(id: String, category: Category, pattern: String, unit: Unit,
                ageTiers: [(days: Int, tier: Tier)], owner: Owner = .none, fileFilter: [String]? = nil,
                exclude: [String] = [], requiresAdmin: Bool = false, requireNotOpen: Bool = false,
                special: Special = .none, reason: String) {
        self.id = id
        self.category = category
        self.pattern = pattern
        self.unit = unit
        self.ageTiers = ageTiers
        self.owner = owner
        self.fileFilter = fileFilter
        self.exclude = exclude
        self.requiresAdmin = requiresAdmin
        self.requireNotOpen = requireNotOpen
        self.special = special
        self.reason = reason
    }

    /// The tier given to items whose age is unknown (size unknown): never auto-ticked.
    var lowestTier: Tier { ageTiers.map(\.tier).min() ?? .info }

    /// Whether `name` is a reverse-DNS bundle id: `^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+){2,}$`.
    static func isBundleID(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+){2,}$"#, options: .regularExpression) != nil
    }
}

/// An item offered for cleaning.
public struct CleanCandidate: Sendable, Identifiable, Equatable {
    public var id: String { path }
    public let path: String
    public let ruleID: String
    public let category: CleanRule.Category
    public let tier: CleanRule.Tier
    public let displayName: String
    public let reason: String
    /// nil = size unknown (unticked).
    public let measurement: Measurement?
    public let requiresAdmin: Bool
    /// Bundle id re-probed before delete.
    public let owner: String?

    public init(path: String, ruleID: String, category: CleanRule.Category, tier: CleanRule.Tier,
                displayName: String, reason: String, measurement: Measurement?, requiresAdmin: Bool,
                owner: String?) {
        self.path = path
        self.ruleID = ruleID
        self.category = category
        self.tier = tier
        self.displayName = displayName
        self.reason = reason
        self.measurement = measurement
        self.requiresAdmin = requiresAdmin
        self.owner = owner
    }
}

/// Why something found was not offered.
public enum SkipReason: Sendable, Equatable {
    /// The owner is running, or (empty id) a process has the item open.
    case appRunning(String)
    case ownerUnknown, recent, protected(Refusal), noAccess, neverClean, macOSSystemCache, installedCheckFailed,
         containsGit, gitTracked, projectInUse, locallyPatched, sameOSInstaller, categoryOff
}

public struct SkippedItem: Sendable, Equatable {
    public let path: String
    public let reason: SkipReason
    public init(path: String, reason: SkipReason) {
        self.path = path
        self.reason = reason
    }
}

public struct CleanReport: Sendable {
    public var candidates: [CleanCandidate]
    public var skipped: [SkippedItem]
    public init(candidates: [CleanCandidate] = [], skipped: [SkippedItem] = []) {
        self.candidates = candidates
        self.skipped = skipped
    }
}

/// A build-artifact folder inside a project (§6.5).
public struct ProjectArtifact: Sendable, Equatable {
    public let path: String
    public let project: String
    public let projectRoot: String
    public init(path: String, project: String, projectRoot: String) {
        self.path = path
        self.project = project
        self.projectRoot = projectRoot
    }
}

/// Everything the engine asks the live system. nil answers mean "couldn't
/// tell", which keeps the item (Skipped).
public protocol CleanProbes: Sendable {
    var now: Date { get }
    func isRunning(bundleID: String) -> Bool?
    func isOpen(path: String) -> Bool?
    /// Gradle daemon check.
    func isProcessRunning(name: String) -> Bool?
    /// The bundle id of the app owning `~/Library/Application Support/<appSupportFolder>` (a folder name).
    func bundleID(appSupportFolder: String) -> String?
    func installedBundleIDs() -> Set<String>?
    func projectArtifacts(roots: [String]) -> [ProjectArtifact]
    /// Process working directories; nil = couldn't tell.
    func workingDirectories() -> [String]?
}
