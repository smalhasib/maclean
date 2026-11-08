import Darwin
import Foundation

/// Runs a rule catalog against the filesystem (spec §6.1–6.3): expands each
/// pattern, applies conditions, measures and classifies. Rules run in order and
/// the first rule to claim a path wins.
public struct CleanEngine {
    public let rules: [CleanRule]
    public let home: String
    public let environment: ProtectionEnvironment
    public let probes: any CleanProbes
    public let disabled: Set<CleanRule.Category>
    public let projectRoots: [String]
    public let budget: Duration

    public init(rules: [CleanRule], home: String, environment: ProtectionEnvironment,
                probes: any CleanProbes, disabled: Set<CleanRule.Category> = [], projectRoots: [String] = [],
                budget: Duration = .seconds(5)) {
        self.rules = rules
        self.home = home
        self.environment = environment
        self.probes = probes
        self.disabled = disabled
        self.projectRoots = projectRoots
        self.budget = budget
    }

    // MARK: - Run

    /// Checks every rule. `progress` receives each item's path before it is measured.
    public func run(progress: @Sendable (String) -> Void = { _ in }) async -> CleanReport {
        var report = CleanReport()
        var claimed: [String] = []      // items an earlier rule took (offered or skipped)
        var roots: [String] = []        // folders earlier rules target; later rules never offer their ancestors
        var denied: Set<String> = []
        let context = MeasureContext()

        for rule in rules {
            if Task.isCancelled { break }
            guard offersAnything(rule) else { continue }
            let expansion = Self.units(of: rule, home: home)
            let blocked = { (p: String) in
                claimed.contains { PathUtil.isInside(p, orEqualTo: $0) || PathUtil.isInside($0, orEqualTo: p) }
                    || roots.contains { PathUtil.isInside($0, orEqualTo: p) }
            }
            let items = expansion.items.filter { !blocked($0) && Self.claims(rule, path: $0, checkType: true) }
            for d in expansion.denied where !blocked(d) && denied.insert(d).inserted {
                report.skipped.append(SkippedItem(path: d, reason: .noAccess))
            }
            claimed += items
            roots += expansion.roots

            if disabled.contains(rule.category) {
                report.skipped += items.map { SkippedItem(path: $0, reason: .categoryOff) }
                continue
            }
            let kept = keptNewest(items, rule: rule)
            for path in items {
                if kept.contains(path) {
                    report.skipped.append(SkippedItem(path: path, reason: .recent))
                    continue
                }
                progress(path)
                switch evaluate(path, rule: rule, context: context) {
                case .offer(let c): report.candidates.append(c)
                case .skip(let r): report.skipped.append(SkippedItem(path: path, reason: r))
                case .gone: break
                }
            }
        }
        return report
    }

    private enum Verdict { case offer(CleanCandidate), skip(SkipReason), gone }

    /// Steps 4–7 for one claimed item.
    private func evaluate(_ path: String, rule: CleanRule, context: MeasureContext) -> Verdict {
        if let r = ProtectionRules.refusal(for: path, context: .smartClean, in: environment) {
            switch r {
            case .neverClean: return .skip(.neverClean)
            case .appleSystem: return .skip(.macOSSystemCache)
            default: return .skip(.protected(r))
            }
        }

        let measurement: Measurement?
        do {
            measurement = try Measurer.measure(path, context: context, deadline: .now + budget)
        } catch .timedOut {
            measurement = nil
        } catch .notFound {
            return .gone
        } catch {
            guard rule.requiresAdmin else { return .skip(.noAccess) }
            measurement = nil
        }

        let tier: CleanRule.Tier
        if let measurement {
            let age = Int((probes.now.timeIntervalSince(measurement.newest) / 86400).rounded(.down))
            guard let match = rule.ageTiers.first(where: { $0.days <= age }) else { return .skip(.recent) }
            tier = match.tier
        } else {
            tier = rule.sizeUnknownTier
        }

        var owner: String?
        switch rule.owner {
        case .none: break
        case .bundleID(let id): owner = id
        case .childNameIfBundleID: owner = Self.ownName(path)
        case .containerBundleID: owner = Self.component(after: "Containers", in: path)
        case .appSupportFolder:
            guard let folder = Self.component(after: "Application Support", in: path),
                  let id = probes.bundleID(appSupportFolder: folder) else { return .skip(.ownerUnknown) }
            owner = id
        case .processName(let name):
            switch probes.isProcessRunning(name: name) {
            case false?: break
            case true?: return .skip(.appRunning(name))
            case nil: return .skip(.ownerUnknown)
            }
        }
        if let owner {
            switch probes.isRunning(bundleID: owner) {
            case false?: break
            case true?: return .skip(.appRunning(owner))
            case nil: return .skip(.ownerUnknown)
            }
        }
        if case .containerBundleID = rule.owner, let r = openCheck(path, owner: owner) { return .skip(r) }
        else if rule.requireNotOpen, let r = openCheck(path, owner: owner) { return .skip(r) }

        return .offer(CleanCandidate(
            path: path, ruleID: rule.id, category: rule.category, tier: tier,
            displayName: (path as NSString).lastPathComponent, reason: rule.reason,
            measurement: measurement, requiresAdmin: rule.requiresAdmin, owner: owner))
    }

    private func openCheck(_ path: String, owner: String?) -> SkipReason? {
        switch probes.isOpen(path: path) {
        case false?: nil
        case true?: owner.map { .appRunning($0) } ?? .inUse
        case nil: .ownerUnknown
        }
    }

    /// Specials not implemented yet offer nothing and claim nothing.
    private func offersAnything(_ rule: CleanRule) -> Bool {
        switch rule.special {
        case .none, .keepNewest, .derivedData: true
        case .removedAppLeftover, .projectArtifacts, .launchdOrphan, .macOSInstaller, .downloadsInstaller: false
        }
    }

    /// `.keepNewest(n)`: the n newest items (by mtime, then name) of each parent folder.
    private func keptNewest(_ items: [String], rule: CleanRule) -> Set<String> {
        guard case .keepNewest(let n) = rule.special else { return [] }
        var kept: Set<String> = []
        for (_, group) in Dictionary(grouping: items, by: { ($0 as NSString).deletingLastPathComponent }) {
            let sorted = group.map { p -> (String, Int) in
                var st = stat()
                return (p, lstat(p, &st) == 0 ? st.st_mtimespec.tv_sec : 0)
            }.sorted {
                $0.1 != $1.1 ? $0.1 > $1.1
                    : ($0.0 as NSString).lastPathComponent.localizedStandardCompare(($1.0 as NSString).lastPathComponent)
                        == .orderedDescending
            }
            kept.formUnion(sorted.prefix(n).map(\.0))
        }
        return kept
    }

    // MARK: - Matching (string only)

    public func rule(matching path: String) -> CleanRule? {
        Self.rule(matching: path, in: rules, home: home)
    }

    /// The first rule in catalog order whose pattern and unit produce exactly
    /// `path`, and whose name conditions (exclude, file filter, bundle-id owner)
    /// accept it. String-only, so it can't see which app is installed:
    /// `.removedAppLeftover` rules are passed over and the answer is the rule
    /// that claims the path while its app is installed.
    public static func rule(matching path: String, in rules: [CleanRule], home: String) -> CleanRule? {
        guard path.hasPrefix("/") else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        if parts.contains(where: { $0 == "." || $0 == ".." }) { return nil }
        return rules.first { rule in
            if case .removedAppLeftover = rule.special { return false }
            return patterns(of: rule, home: home).contains { segments in
                segments.count == parts.count && zip(segments, parts).enumerated().allSatisfy { i, pair in
                    // The `.eachChild` segment of a rule that offers hidden children matches any name.
                    if i == parts.count - 1, rule.offersHiddenChildren, case .eachChild = rule.unit { return true }
                    return glob(pair.0, pair.1)
                }
            } && claims(rule, path: path, checkType: false)
        }
    }

    /// The rule's patterns as absolute path segments, with a trailing `*` for `.eachChild`.
    private static func patterns(of rule: CleanRule, home: String) -> [[String]] {
        braceExpand(rule.pattern).compactMap { p in
            guard let (base, segments) = resolve(p, home: home) else { return nil }
            let all = base.split(separator: "/").map(String.init) + segments
            if case .eachChild = rule.unit { return all + ["*"] }
            return all
        }
    }

    /// The rule's name conditions. `checkType` also requires a regular file for `fileFilter` rows.
    static func claims(_ rule: CleanRule, path: String, checkType: Bool) -> Bool {
        let name = (path as NSString).lastPathComponent
        if rule.exclude.contains(where: { glob($0, name) }) { return false }
        if let filter = rule.fileFilter {
            guard filter.contains(where: { glob($0, name) }) else { return false }
            if checkType {
                var st = stat()
                guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return false }
            }
        }
        if case .childNameIfBundleID = rule.owner, case .eachChild = rule.unit, ownName(path) == nil { return false }
        return true
    }

    /// The item's name without `.savedState`, if that is a bundle id.
    private static func ownName(_ path: String) -> String? {
        var name = (path as NSString).lastPathComponent
        if name.hasSuffix(".savedState") { name = String(name.dropLast(".savedState".count)) }
        return CleanRule.isBundleID(name) ? name : nil
    }

    private static func component(after marker: String, in path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(of: marker), i + 1 < parts.count else { return nil }
        return parts[i + 1]
    }

    // MARK: - Expansion (filesystem, no symlink following)

    /// All existing paths matching `pattern`. `~` is `home`. Every directory
    /// passed through below the base is checked with `lstat`, so a symlinked
    /// folder is never entered; the final segment may be any type.
    public static func expand(_ pattern: String, home: String) -> [String] {
        var seen: Set<String> = []
        return braceExpand(pattern).flatMap { p -> [String] in
            guard let (base, segments) = resolve(p, home: home) else { return [] }
            return glob(base: base, segments: segments)
        }.filter { seen.insert($0).inserted }
    }

    struct Expansion { var roots: [String] = []; var items: [String] = []; var denied: [String] = [] }

    /// Pattern matches (`roots`) and the items the unit offers. Unreadable
    /// `.eachChild` folders land in `denied`.
    static func units(of rule: CleanRule, home: String) -> Expansion {
        var e = Expansion()
        e.roots = expand(rule.pattern, home: home)
        switch rule.unit {
        case .folder: e.items = e.roots
        case .eachChild:
            for dir in e.roots where isRealDirectory(dir) {
                switch list(dir) {
                case .success(let names): e.items += names.filter { rule.offersHiddenChildren || !$0.hasPrefix(".") }.sorted().map { join(dir, $0) }
                case .failure(let err) where err.code == .EACCES || err.code == .EPERM: e.denied.append(dir)
                case .failure: break
                }
            }
        }
        return e
    }

    private static func glob(base: String, segments: [String]) -> [String] {
        var current = [base]
        for (i, seg) in segments.enumerated() {
            let last = i == segments.count - 1
            var next: [String] = []
            for dir in current {
                if seg.contains(where: { "*?[".contains($0) }) {
                    guard case .success(let names) = list(dir) else { continue }
                    for name in names.sorted() where glob(seg, name) {
                        let p = join(dir, name)
                        if last || isRealDirectory(p) { next.append(p) }
                    }
                } else {
                    let p = join(dir, seg)
                    var st = stat()
                    if last ? lstat(p, &st) == 0 : isRealDirectory(p) { next.append(p) }
                }
            }
            current = next
        }
        return segments.isEmpty ? [] : current
    }

    /// `~` / `~/…` → (home, segments); `/…` → ("/", segments); anything else is invalid.
    private static func resolve(_ pattern: String, home: String) -> (String, [String])? {
        let split = { (s: Substring) in s.split(separator: "/").map(String.init) }
        if pattern == "~" { return (home, []) }
        if pattern.hasPrefix("~/") { return (home, split(pattern.dropFirst(2))) }
        if pattern.hasPrefix("/") { return ("/", split(pattern.dropFirst())) }
        return nil
    }

    /// Expands the first `{a,b}` group (recursively), over the whole string.
    static func braceExpand(_ s: String) -> [String] {
        guard let open = s.firstIndex(of: "{") else { return [s] }
        var depth = 0, parts: [String] = [], start = s.index(after: open)
        var i = open
        while i < s.endIndex {
            switch s[i] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    parts.append(String(s[start..<i]))
                    let head = s[..<open], tail = String(s[s.index(after: i)...])
                    return parts.flatMap { braceExpand(head + $0 + tail) }
                }
            case "," where depth == 1:
                parts.append(String(s[start..<i]))
                start = s.index(after: i)
            default: break
            }
            i = s.index(after: i)
        }
        return [s]      // unbalanced: literal
    }

    private static func glob(_ pattern: String, _ name: String) -> Bool {
        fnmatch(pattern, name, FNM_PERIOD) == 0
    }

    private static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    private static func isRealDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    /// Names in `dir`, opened with `O_NOFOLLOW` so a swapped-in symlink isn't listed.
    private static func list(_ dir: String) -> Result<[String], POSIXError> {
        let fd = open(dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)) }
        guard let d = fdopendir(fd) else {
            let err = errno
            close(fd)
            return .failure(POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO))
        }
        defer { closedir(d) }
        var names: [String] = []
        while let entry = readdir(d) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return .success(names)
    }
}
