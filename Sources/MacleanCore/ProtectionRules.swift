import Foundation

/// Which feature asks. `.smartClean` adds the strict rules of spec §6.4 on top of the collector's.
public enum ProtectionContext: String, Sendable {
    case collector
    case smartClean = "smart-clean"
}

public enum Refusal: String, Sendable, Codable, Equatable {
    case systemProtected, volumeRoot, libraryItself, homeItself, macleanItself, timeMachine, unsafePath
    // Smart Clean only.
    case criticalRoot, personalData, neverClean, protectedApp, appleSystem

    public func message(name: String) -> String {
        switch self {
        case .systemProtected: "“\(name)” is protected by macOS and can't be deleted."
        case .volumeRoot: "“\(name)” is a whole disk. Collect the folders inside it instead."
        case .libraryItself: "“Library” is needed by macOS. Collect the folders inside it instead."
        case .homeItself: "Your home folder can't be collected. Collect the folders inside it instead."
        case .macleanItself: "Maclean can't delete itself."
        case .timeMachine: "Items on Time Machine backups can't be deleted."
        case .unsafePath: "This item's path can't be deleted safely."
        case .criticalRoot: "“\(name)” is an important folder. Smart Clean only removes items inside it."
        case .personalData: "“\(name)” holds personal data, so Smart Clean leaves it alone."
        case .neverClean: "“\(name)” is on your never-clean list."
        case .protectedApp: "“\(name)” belongs to a protected app (security, passwords or network)."
        case .appleSystem: "“\(name)” is a macOS system cache and isn't offered."
        }
    }
}

public struct ProtectionEnvironment: Sendable, Codable, Equatable {
    public var home: String
    public var appBundle: String
    public var mountPoints: [String]
    public var timeMachineMounts: [String]
    /// The user's never-clean list (Smart Clean only; entries may start with `~/`).
    /// Root may take it from the app: it can only deny.
    public var neverClean: [String]

    public init(home: String, appBundle: String, mountPoints: [String], timeMachineMounts: [String],
                neverClean: [String] = []) {
        self.home = home
        self.appBundle = appBundle
        self.mountPoints = mountPoints
        self.timeMachineMounts = timeMachineMounts
        self.neverClean = neverClean
    }

    private enum CodingKeys: String, CodingKey { case home, appBundle, mountPoints, timeMachineMounts, neverClean }

    /// Tolerates a missing `neverClean` key (older `--env` JSON).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        home = try c.decode(String.self, forKey: .home)
        appBundle = try c.decode(String.self, forKey: .appBundle)
        mountPoints = try c.decode([String].self, forKey: .mountPoints)
        timeMachineMounts = try c.decode([String].self, forKey: .timeMachineMounts)
        neverClean = try c.decodeIfPresent([String].self, forKey: .neverClean) ?? []
    }

    public static func current() -> ProtectionEnvironment {
        let mounts = ScanBoundary.mounts().map(\.path)
        let tm = mounts.filter {
            PathUtil.isInside($0, orEqualTo: "/Volumes/.timemachine")
                || FileManager.default.fileExists(atPath: ($0 as NSString).appendingPathComponent("Backups.backupdb"))
        }
        return ProtectionEnvironment(home: NSHomeDirectory(), appBundle: Bundle.main.bundlePath,
                                     mountPoints: mounts, timeMachineMounts: tm)
    }
}

public enum ProtectionRules {
    /// Why the collector must refuse `path`, or nil if it may be collected.
    /// Pure string logic: symlinks are not resolved. Comparisons are
    /// component-wise and case-insensitive (APFS default).
    public static func refusal(for path: String, context: ProtectionContext = .collector,
                               in env: ProtectionEnvironment) -> Refusal? {
        if let r = collectorRefusal(for: path, in: env) { return r }
        guard context == .smartClean else { return nil }

        // A symlinked ancestor could redirect the delete: refuse, and let the
        // resolved path's own verdict win. It can only deny, never allow.
        guard let parts = components(of: path) else { return .unsafePath }
        let parent = "/" + parts.dropLast().joined(separator: "/")
        guard let resolved = realpathString(parent) else { return .unsafePath }
        if canonical(parts.dropLast().map { $0 }) != normalized(resolved) {
            let full = resolved == "/" ? "/" + (parts.last ?? "") : resolved + "/" + (parts.last ?? "")
            return collectorRefusal(for: full, in: env) ?? smartCleanRefusal(for: full, in: env) ?? .unsafePath
        }
        return smartCleanRefusal(for: path, in: env)
    }

    // MARK: - Smart Clean (spec §6.4)

    /// Protected bundle-id prefixes (Maclean's own list): password managers,
    /// input methods, VPNs and security/EDR tools. Matched per path component.
    public static let protectedBundlePrefixes: [String] = [
        // password managers
        "com.1password", "com.agilebits", "com.bitwarden", "com.lastpass", "com.dashlane",
        "org.keepassxc", "com.keepersecurity", "com.enpass", "com.stagecoach.strongbox",
        // input methods
        "com.sogou", "com.baidu.inputmethod", "com.tencent.inputmethod", "im.rime", "org.fcitx",
        "com.googlecode.rimeime", "com.google.inputmethod", "org.pqrs",
        // VPNs
        "com.nordvpn", "com.nordsec", "com.expressvpn", "ch.protonvpn", "com.protonvpn", "net.mullvad",
        "com.wireguard", "io.tailscale", "com.tailscale", "net.tunnelblick", "com.cisco.anyconnect",
        "com.paloaltonetworks", "com.privateinternetaccess",
        // security / EDR / MDM
        "com.crowdstrike", "com.sentinelone", "com.jamf", "com.microsoft.wdav", "com.objective-see",
        "com.malwarebytes", "com.sophos", "com.carbonblack", "com.vmware.carbonblack", "com.kandji",
        "com.mosyle", "com.eset", "com.bitdefender", "com.avast", "com.f-secure",
    ]

    /// `com.apple.*` components Smart Clean may offer: the §6.2 list, the §6.2a
    /// names, and `com.apple.mail` (only its `Data/Library/Mail Downloads`).
    /// `*` is a glob.
    public static let appleAllowlist: [String] = [
        "com.apple.Safari", "com.apple.dt.Xcode", "com.apple.WebKit.*", "com.apple.QuickLook.thumbnailcache",
        "com.apple.iconservices.store", "com.apple.akd", "com.apple.photoanalysisd", "com.apple.helpd",
        "com.apple.Suggestions", "com.apple.IdentityCaches", "GeoServices", "com.apple.ap.adprivacyd",
        "com.apple.metal", "com.apple.metalfe", "com.apple.gpuarchiver", "com.apple.idleassetsd",
        "com.apple.mail",
    ]

    private static let mailDownloads = ["data", "library", "mail downloads"]
    private static let browserCacheDirs: Set<String> =
        ["cache", "code cache", "gpucache", "shadercache", "dawncache", "grshadercache"]
    /// Browser profile roots, relative to `Application Support`, folded.
    private static let browserRoots: [[String]] = [
        ["google", "chrome"], ["chromium"], ["bravesoftware", "brave-browser"], ["microsoft edge"],
        ["arc", "user data"], ["vivaldi"], ["com.operasoftware.opera"], ["firefox"],
    ]
    private static let personalNames: Set<String> =
        ["keychains", "accounts", "mail", "messages", "calendars", "contacts", "mobile documents"]
    private static let safariFiles: Set<String> = ["history.db", "bookmarks.plist", "localstorage"]

    private static let criticalAbsolute = ["/", "/Applications", "/Users", "/Users/Shared", "/Volumes",
                                           "/opt/homebrew", "/etc", "/private/etc", "/private/var/db",
                                           "/Library/Caches", "/Library/Logs", "/Library/Application Support",
                                           "/private/var/log"]
    private static let criticalInHome = ["Library", "Library/Caches", "Library/Containers",
                                         "Library/Application Support", "Library/Logs", "Library/Developer"]
    private static let privateAllowed = ["/private/var/log", "/private/var/db/diagnostics",
                                         "/private/var/db/reportmemoryexception"]

    /// The current user's `/private/var/folders/<x>/<y>`, from `confstr`.
    private static let userFoldersDir: String? = {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(Int32(_CS_DARWIN_USER_CACHE_DIR), &buf, buf.count) > 0 else { return nil }
        let dir = String(cString: buf)
        return (dir as NSString).deletingLastPathComponent       // drops the trailing `C`
    }()

    /// Rules 3-8 of §6.4 on a path that already passed the collector rules.
    private static func smartCleanRefusal(for path: String, in env: ProtectionEnvironment) -> Refusal? {
        guard var p = components(of: path).map(canonical) else { return .unsafePath }
        if p.count >= 3, p[0] == "system", p[1] == "volumes", p[2] == "data" {
            p.removeFirst(3)
            canonicalInPlace(&p)
        }
        let home = env.home
        let critical = criticalAbsolute + criticalInHome.map { home + "/" + $0 }
        if critical.contains(where: { equal(p, $0) }) || (p.count == 2 && p[0] == "users") { return .criticalRoot }

        if isPersonalData(p) { return .personalData }
        if env.neverClean.contains(where: { entry in
            let e = normalized(entry.hasPrefix("~/") ? home + entry.dropFirst() : entry == "~" ? home : entry)
            return !e.isEmpty && (p.starts(with: e) || e.starts(with: p))
        }) { return .neverClean }

        if p.contains(where: { c in protectedBundlePrefixes.contains { c.hasPrefix($0.lowercased()) } }) {
            return .protectedApp
        }
        for (i, c) in p.enumerated() where c.hasPrefix("com.apple.") {
            if !appleAllowed(c, rest: p[(i + 1)...]) { return .appleSystem }
        }

        if p.first == "private" {
            let allowed = privateAllowed.contains { inside(p, root: $0) && p.count > normalized($0).count }
            if !allowed && !inUserFolders(p) { return .criticalRoot }
        }
        return nil
    }

    private static func inUserFolders(_ p: [String]) -> Bool {
        guard let dir = userFoldersDir else { return false }
        return inside(p, root: dir) && p.count > normalized(dir).count
    }

    private static func appleAllowed(_ component: String, rest: ArraySlice<String>) -> Bool {
        if component == "com.apple.mail" { return rest.starts(with: mailDownloads) }
        return appleAllowlist.contains { entry in
            entry != "com.apple.mail" && fnmatch(entry.lowercased(), component, 0) == 0
        }
    }

    private static func isPersonalData(_ p: [String]) -> Bool {
        if p.contains(where: { personalNames.contains($0) || $0.hasSuffix(".photoslibrary") }) { return true }
        if let i = p.firstIndex(where: { $0 == "safari" || $0 == "com.apple.safari" }),
           p[(i + 1)...].contains(where: { safariFiles.contains($0) }) { return true }
        // Browser profile data: refused unless inside a cache folder.
        if let i = p.firstIndex(of: "application support") {
            let below = p[(i + 1)...]
            for root in browserRoots where below.starts(with: root) {
                return !below.dropFirst(root.count).contains(where: { browserCacheDirs.contains($0) })
            }
        }
        return false
    }

    private static func realpathString(_ path: String) -> String? {
        guard let r = realpath(path, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    private static func collectorRefusal(for path: String, in env: ProtectionEnvironment) -> Refusal? {
        guard var parts = components(of: path) else { return .unsafePath }
        parts = canonical(parts)

        if env.timeMachineMounts.contains(where: { inside(parts, root: $0) })
            || inside(parts, root: "/Volumes/.timemachine/x", depth: 2) {
            return .timeMachine
        }
        if env.mountPoints.contains(where: { equal(parts, $0) }) { return .volumeRoot }

        // The Data volume is an alias of the root: keep the root path's verdict.
        if parts.count >= 3, parts[0] == "system", parts[1] == "volumes", parts[2] == "data" {
            parts.removeFirst(3)
            canonicalInPlace(&parts)
            if parts.first?.hasPrefix(".") == true { return .systemProtected }
        }

        // Maclean is checked first: when the app sits inside the home folder
        // its own bundle and ancestors report .macleanItself. Strict
        // ancestors are refused too, so a parent can't take the app or the
        // home folder with it. An empty or "/" home/appBundle counts as absent.
        let app = normalized(env.appBundle), home = normalized(env.home)
        if !app.isEmpty, parts.starts(with: app) || (parts.count < app.count && app.starts(with: parts)) {
            return .macleanItself
        }
        if !home.isEmpty, parts.count <= home.count, home.starts(with: parts) { return .homeItself }
        if parts == ["library"] { return .libraryItself }
        return isSystem(parts) ? .systemProtected : nil
    }

    // MARK: - Helpers

    private static func components(of path: String) -> [String]? {
        guard path.hasPrefix("/") else { return nil }
        for u in path.unicodeScalars where u.value < 0x20 || (0x7F...0x9F).contains(u.value) { return nil }
        if path == "/" { return [] }
        let parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) { return nil }
        return parts
    }

    /// Lowercased, with `/var`, `/etc`, `/tmp` rewritten to their `/private` form.
    private static func canonical(_ parts: [String]) -> [String] {
        var p = parts.map(fold)
        canonicalInPlace(&p)
        return p
    }

    /// NFC then lowercase, so NFD and NFC spellings compare equal.
    private static func fold(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }

    private static func canonicalInPlace(_ p: inout [String]) {
        if let first = p.first, ["var", "etc", "tmp"].contains(first) { p.insert("private", at: 0) }
    }

    private static func normalized(_ path: String) -> [String] {
        let parts = path.split(separator: "/").map { fold(String($0)) }
        return canonical(parts)
    }

    private static func equal(_ parts: [String], _ root: String) -> Bool { parts == normalized(root) }

    private static func inside(_ parts: [String], root: String, depth: Int? = nil) -> Bool {
        let r = normalized(root)
        let n = depth ?? r.count
        return parts.count >= n && Array(parts.prefix(n)) == Array(r.prefix(n))
    }

    private static func isSystem(_ p: [String]) -> Bool {
        guard let top = p.first else { return true }                    // "/"
        switch top {
        case "system", "bin", "sbin", "dev", "cores", "home", "net": return true
        case "usr": return !(p.count >= 2 && p[1] == "local")
        case "applications", "users", "volumes", "opt": return p.count == 1 || (top == "users" && p.count == 2 && p[1] == "shared")
        case "library":
            return p.count >= 2 && (p[1] == "apple" || p[1] == "extensions")
        case "private":
            guard p.count >= 2 else { return true }
            switch p[1] {
            case "etc": return true
            case "tmp": return p.count == 2
            case "var":
                guard p.count >= 3 else { return true }
                if ["db", "root", "audit"].contains(p[2]) { return true }
                return p[2] == "folders" && p.count == 3
            default: return false
            }
        default: return false
        }
    }
}
