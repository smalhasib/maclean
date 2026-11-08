import Darwin
import Foundation

/// The rule specials (spec §6.2, §6.2a, §6.6): which items a special claims,
/// and the checks, names and reasons it adds. `CleanEngine.run` stays the pipeline.
extension CleanEngine {
    static func needsInstalledSet(_ rule: CleanRule) -> Bool {
        switch rule.special {
        case .removedAppLeftover, .launchdOrphan: true
        default: false
        }
    }

    /// A removed-app leftover rule claims only a bundle-id name (not `com.apple.*`)
    /// whose app isn't installed, or every bundle-id name when the installed check
    /// failed (it is then skipped, never offered as a generic cache). Everything
    /// else falls through to the later rules. `installed` is lowercased.
    static func specialClaims(_ rule: CleanRule, path: String, installed: Set<String>?) -> Bool {
        guard case .removedAppLeftover = rule.special else { return true }
        guard let name = ownName(path)?.lowercased(), !name.hasPrefix("com.apple.") else { return false }
        guard let installed else { return true }
        return !isInstalled(name, in: installed)
    }

    /// Exact match, or a helper of an installed id, or an id with an installed helper.
    static func isInstalled(_ id: String, in installed: Set<String>) -> Bool {
        installed.contains(id) || installed.contains { id.hasPrefix($0 + ".") || $0.hasPrefix(id + ".") }
    }

    /// Leftovers never offered when their name contains one of these (Maclean's own list).
    static let neverDeleteWords = ["1password", "keychain", "bitwarden", "ssh", "gpg", "lastpass", "dashlane", "keepass"]

    enum SpecialPrep { case proceed(displayName: String, reason: String), skip(SkipReason), drop }

    /// The special's checks before measuring, with the display name and reason it sets.
    func prepareSpecial(_ path: String, rule: CleanRule, installed: Set<String>?) -> SpecialPrep {
        let name = (path as NSString).lastPathComponent
        switch rule.special {
        case .removedAppLeftover:
            guard installed != nil else { return .skip(.installedCheckFailed) }
            let id = Self.ownName(path) ?? name
            if Self.neverDeleteWords.contains(where: { id.lowercased().contains($0) }) {
                return .skip(.protected(.protectedApp))
            }
            return .proceed(displayName: Self.guessedAppName(id), reason: rule.reason)
        case .skipIfSecurityTool:
            return probes.securityToolInstalled() ? .skip(.protected(.protectedApp))
                : .proceed(displayName: name, reason: rule.reason)
        case .launchdOrphan:
            switch Self.orphanCheck(path, installed: installed) {
            case .orphan(let missing): return .proceed(displayName: name, reason: "\(rule.reason): \(missing)")
            case .notOrphan: return .drop
            case .unknown(let r): return .skip(r)
            }
        case .derivedData:
            return .proceed(displayName: Self.derivedDataProject(path) ?? name, reason: rule.reason)
        default:
            return .proceed(displayName: name, reason: rule.reason)
        }
    }

    /// The date an item's age counts from: when a Downloads installer arrived;
    /// else the measured newest; else (size unknown) the item's own newest of
    /// mtime and ctime. nil if it can't be read.
    static func ageDate(_ path: String, rule: CleanRule, measurement: Measurement?) -> Date? {
        if case .downloadsInstaller = rule.special { return dateAdded(path) }
        if let measurement { return measurement.newest }
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return max(date(st.st_mtimespec), date(st.st_ctimespec))
    }

    /// `com.gone.app` → `App`.
    static func guessedAppName(_ bundleID: String) -> String {
        let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    enum Orphan { case orphan(String), notOrphan, unknown(SkipReason) }

    /// A launchd plist whose absolute `Program`/`ProgramArguments[0]` is missing, or
    /// a helper tool none of whose owning apps (embedded `SMAuthorizedClients`,
    /// else its own `CFBundleIdentifier`) is installed.
    static func orphanCheck(_ path: String, installed: Set<String>?) -> Orphan {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return .unknown(.ownerUnknown) }
        if path.hasSuffix(".plist") {
            let dict: [String: Any]
            switch PlistReader.dictionary(atPath: path) {
            case .success(let d): dict = d
            case .failure(.malformed): return .unknown(.ownerUnknown)
            case .failure: return .unknown(.noAccess)
            }
            let program = dict["Program"] as? String ?? (dict["ProgramArguments"] as? [String])?.first
            guard let program, program.hasPrefix("/") else { return .notOrphan }
            return programMissing(program)
        }
        guard st.st_size <= 64 << 20, let data = FileManager.default.contents(atPath: path) else {
            return .unknown(.noAccess)
        }
        let owners = helperOwnerIDs(data)
        guard !owners.isEmpty else { return .unknown(.ownerUnknown) }
        guard let installed else { return .unknown(.installedCheckFailed) }
        if owners.contains(where: { isInstalled($0.lowercased(), in: installed) }) { return .notOrphan }
        return .orphan(owners.joined(separator: ", "))
    }

    /// Missing program → orphan; on an unmounted volume (`/Volumes/<name>` absent) → unknown.
    private static func programMissing(_ program: String) -> Orphan {
        var st = stat()
        guard lstat(program, &st) != 0, errno == ENOENT || errno == ENOTDIR else { return .notOrphan }
        let parts = program.split(separator: "/")
        if parts.count >= 2, parts[0] == "Volumes", lstat("/Volumes/\(parts[1])", &st) != 0 {
            return .unknown(.ownerUnknown)
        }
        return .orphan(program)
    }

    /// The owning app ids of a helper binary, from its embedded Info.plist: every
    /// `identifier` in its `SMAuthorizedClients` requirements, else its own id.
    public static func helperOwnerIDs(_ binary: Data) -> [String] {
        guard let start = binary.range(of: Data("<?xml".utf8)),
              let end = binary.range(of: Data("</plist>".utf8), in: start.upperBound..<binary.endIndex),
              let dict = PlistReader.dictionary(from: binary[start.lowerBound..<end.upperBound])
        else { return [] }
        let pattern = try! NSRegularExpression(pattern: #"identifier\s+"?([A-Za-z0-9.\-]+)"?"#)
        var clients: [String] = []
        for req in dict["SMAuthorizedClients"] as? [String] ?? [] {
            for m in pattern.matches(in: req, range: NSRange(req.startIndex..., in: req)) {
                if let r = Range(m.range(at: 1), in: req), !clients.contains(String(req[r])) { clients.append(String(req[r])) }
            }
        }
        if !clients.isEmpty { return clients }
        return (dict["CFBundleIdentifier"] as? String).map { [$0] } ?? []
    }

    /// `kMDItemDateAdded` (when the file arrived in its folder), else the birth time.
    static func dateAdded(_ path: String) -> Date? {
        let name = "com.apple.metadata:kMDItemDateAdded"
        var buf = [UInt8](repeating: 0, count: 256)
        let n = getxattr(path, name, &buf, buf.count, 0, XATTR_NOFOLLOW)
        if n > 0, let added = try? PropertyListSerialization.propertyList(from: Data(buf.prefix(n)), format: nil) as? Date {
            return added
        }
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return date(st.st_birthtimespec)
    }

    /// Whether a macOS installer's `CFBundleShortVersionString` names the running
    /// macOS (`15.1` == `15.1.0`); nil if it can't be read.
    static func installerMatchesRunningOS(_ app: String) -> Bool? {
        guard let version = PlistReader.string("CFBundleShortVersionString",
                                               atPath: (app as NSString).appendingPathComponent("Contents/Info.plist"))
        else { return nil }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        func trimmed(_ parts: [String]) -> [String] {
            var p = parts
            while p.count > 1, p.last.flatMap(Int.init) == 0 { p.removeLast() }
            return p
        }
        let running = ["\(os.majorVersion)", "\(os.minorVersion)", "\(os.patchVersion)"]
        return trimmed(version.split(separator: ".").map(String.init)) == trimmed(running)
    }

    /// The project name from a DerivedData folder's `info.plist` `WorkspacePath`.
    static func derivedDataProject(_ folder: String) -> String? {
        guard let workspace = PlistReader.string("WorkspacePath",
                                                 atPath: (folder as NSString).appendingPathComponent("info.plist")),
              !workspace.isEmpty
        else { return nil }
        return ((workspace as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    private static func date(_ t: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_nsec) / 1e9)
    }
}
