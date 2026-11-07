import Foundation

public enum ProtectionContext: Sendable { case collector }

public enum Refusal: String, Sendable, Codable, Equatable {
    case systemProtected, volumeRoot, libraryItself, homeItself, macleanItself, timeMachine, unsafePath

    public func message(name: String) -> String {
        switch self {
        case .systemProtected: "“\(name)” is protected by macOS and can't be deleted."
        case .volumeRoot: "“\(name)” is a whole disk. Collect the folders inside it instead."
        case .libraryItself: "“Library” is needed by macOS. Collect the folders inside it instead."
        case .homeItself: "Your home folder can't be collected. Collect the folders inside it instead."
        case .macleanItself: "Maclean can't delete itself."
        case .timeMachine: "Items on Time Machine backups can't be deleted."
        case .unsafePath: "This item's path can't be deleted safely."
        }
    }
}

public struct ProtectionEnvironment: Sendable, Codable, Equatable {
    public var home: String
    public var appBundle: String
    public var mountPoints: [String]
    public var timeMachineMounts: [String]

    public init(home: String, appBundle: String, mountPoints: [String], timeMachineMounts: [String]) {
        self.home = home
        self.appBundle = appBundle
        self.mountPoints = mountPoints
        self.timeMachineMounts = timeMachineMounts
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

        if equal(parts, env.home) { return .homeItself }
        if inside(parts, root: env.appBundle) { return .macleanItself }
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
        var p = parts.map { $0.lowercased() }
        canonicalInPlace(&p)
        return p
    }

    private static func canonicalInPlace(_ p: inout [String]) {
        if let first = p.first, ["var", "etc", "tmp"].contains(first) { p.insert("private", at: 0) }
    }

    private static func normalized(_ path: String) -> [String] {
        let parts = path.split(separator: "/").map { $0.lowercased() }
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
        case "usr": return !(p.count >= 2 && p[1] == "local" && p.count >= 3)
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
