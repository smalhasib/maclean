import CryptoKit
import Darwin
import Foundation

/// The protocol between the app and `maclean-scan --delete`, the helper the
/// app runs as root (through an administrator prompt) for items it couldn't
/// delete itself.
///
/// Arguments: `--delete --env <JSON environment> --items-file <path>
/// --items-sha256 <hex> --context collector|smart-clean`. The items travel in a file (`writeItemsFile`) so a
/// large batch can't exceed the argument size limit; the app removes it after
/// the run (`removeItemsFile`). The file sits in the user's temp folder, so
/// its SHA-256 travels in argv (fixed once the password prompt starts) and
/// root refuses a file that doesn't match.
/// Output: one JSON line per item (`encode`), read back with `decode`.
public enum AdminDelete {
    public struct Item: Codable, Sendable, Equatable {
        public let request: DeleteRequest
        /// Skip the changed-since-scan re-walk (the item was partly deleted
        /// already, or verified as far as the user could read it).
        public let force: Bool

        public init(request: DeleteRequest, force: Bool) {
            self.request = request
            self.force = force
        }
    }

    public enum ParseError: Error, Equatable { case usage, malformed(String) }

    public static func arguments(itemsFile: String, sha256: String, environment: ProtectionEnvironment,
                                 context: ProtectionContext) -> [String] {
        ["--delete", "--env", json(environment), "--items-file", itemsFile, "--items-sha256", sha256,
         "--context", context.rawValue]
    }

    /// Writes `items` as JSON to a new file (mode 0600) in a fresh private
    /// temporary directory (mode 0700) and returns the file's URL and the
    /// SHA-256 (lowercase hex) of the bytes written.
    public static func writeItemsFile(_ items: [Item]) throws -> (url: URL, sha256: String) {
        try writePrivateFile(Data(json(items).utf8), name: "items.json")
    }

    /// Writes `data` to a new file `name` (mode 0600) in a fresh private
    /// temporary directory (mode 0700); returns its URL and SHA-256.
    static func writePrivateFile(_ data: Data, name: String) throws -> (url: URL, sha256: String) {
        var template = Array((NSTemporaryDirectory() as NSString)
            .appendingPathComponent("maclean-admin-XXXXXX").utf8CString)
        guard let dir = mkdtemp(&template) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let directory = URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        let file = directory.appending(path: name)
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            let e = errno
            removeItemsFile(file)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            removeItemsFile(file)
            throw error
        }
        return (file, sha256(data))
    }

    /// Removes an items file written by `writeItemsFile` and its directory.
    public static func removeItemsFile(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    public static func parse(_ arguments: [String]) throws
        -> (items: [Item], environment: ProtectionEnvironment, context: ProtectionContext) {
        guard arguments.count == 9, arguments[0] == "--delete", arguments[1] == "--env",
              arguments[3] == "--items-file", arguments[5] == "--items-sha256", arguments[7] == "--context",
              let context = ProtectionContext(rawValue: arguments[8]) else {
            throw ParseError.usage
        }
        let decoder = JSONDecoder()
        do {
            let env = try decoder.decode(ProtectionEnvironment.self, from: Data(arguments[2].utf8))
            let data = try readVerifiedFile(path: arguments[4], sha256: arguments[6])
            let items = try decoder.decode([Item].self, from: data)
            return (items, env, context)
        } catch {
            throw ParseError.malformed(String(describing: error))
        }
    }

    /// Reads `path` without following a symlink at its last component, and
    /// only if it is a regular file (not a FIFO or device that could block
    /// or stream something else), then requires its SHA-256 to be `sha256`
    /// (the fingerprint the app put in argv). Shared by `--delete` and
    /// `smart-measure`.
    static func readVerifiedFile(path: String, sha256 expected: String, maxSize: Int = .max) throws -> Data {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw ParseError.malformed("not a regular file") }
        guard st.st_size <= maxSize else { throw ParseError.malformed("file too large") }
        let data = try (maxSize == .max ? handle.readToEnd() : handle.read(upToCount: maxSize + 1)) ?? Data()
        guard data.count <= maxSize else { throw ParseError.malformed("file too large") }
        guard sha256(data) == expected else { throw ParseError.malformed("file fingerprint mismatch") }
        return data
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// One JSON line (JSON escapes control characters, so a path with a
    /// newline still gives one line).
    public static func encode(path: String, outcome: DeleteOutcome) -> String {
        json(Line(path: path, outcome: outcome))
    }

    /// Path → outcome for every well-formed line of `output`. Lines may end
    /// in LF or CR (`do shell script` turns LF into CR); others are ignored.
    public static func decode(_ output: String) -> [String: DeleteOutcome] {
        let decoder = JSONDecoder()
        var result: [String: DeleteOutcome] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            if let l = try? decoder.decode(Line.self, from: Data(line.utf8)) { result[l.path] = l.outcome }
        }
        return result
    }

    /// Deletes one item as the root helper does: the parent is opened once,
    /// its real location is checked (`resolvedRefusal(for:parentFD:context:in:)`),
    /// and the same fd is handed to the deleter, so nothing can be swapped
    /// between the check and the removal.
    ///
    /// In the Smart Clean context the item must also be claimed by a catalog
    /// rule that `requiresAdmin` (checked first, on the string), and, measured
    /// through that same parent fd, still be as old as the rule's smallest age
    /// tier (`smartCleanVerdict`). A tampered request can't reach anything else.
    public static func perform(_ item: Item, with deleter: Deleter) async -> DeleteOutcome {
        await perform(item, with: deleter, rules: CleanCatalog.rules, now: Date(),
                      installed: { installedBundleIDs() })
    }

    /// `perform(_:with:)` with the rules, clock and installed-apps set as parameters, for tests.
    static func perform(_ item: Item, with deleter: Deleter, rules: [CleanRule], now: Date,
                        installed: () -> Set<String>?) async -> DeleteOutcome {
        let path = item.request.path
        let smartClean = deleter.context == .smartClean
        if smartClean, adminRule(for: path, rules: rules, home: deleter.environment.home) == nil {
            return .refused(.unsafePath)
        }
        if let refusal = ProtectionRules.refusal(for: path, context: deleter.context, in: deleter.environment) {
            return .refused(refusal)
        }
        let fd: Int32
        switch Deleter.openParent(of: path) {
        case .failure(let early): return early.outcome
        case .success(let opened): fd = opened
        }
        defer { close(fd) }
        if let refusal = resolvedRefusal(for: path, parentFD: fd, context: deleter.context, in: deleter.environment) {
            return .refused(refusal)
        }
        if smartClean, let verdict = smartCleanVerdict(for: path, parentFD: fd, rules: rules,
                                                       home: deleter.environment.home, now: now, installed: installed) {
            return verdict
        }
        return await deleter.delete(item.request, force: item.force, parentFD: fd)
    }

    /// The Smart Clean root check for `path`, or nil when it may be deleted:
    /// - `.refused(.unsafePath)` unless the first catalog rule (in `rules`
    ///   order, `CleanEngine.rule(matching:in:home:)`) claiming `path` has
    ///   `requiresAdmin`;
    /// - `.changedSinceScan` with root's own numbers when, measured now, the
    ///   item is newer than the rule's smallest `ageTiers` days.
    /// The parent is opened once and everything after the rule match is done
    /// relative to it (`smartCleanVerdict(for:parentFD:rules:home:now:)`).
    public static func smartCleanVerdict(for path: String, rules: [CleanRule], home: String,
                                         now: Date) -> DeleteOutcome? {
        smartCleanVerdict(for: path, rules: rules, home: home, now: now, installed: { installedBundleIDs() })
    }

    /// `smartCleanVerdict(for:rules:home:now:)` with the installed-apps set as a parameter, for tests.
    static func smartCleanVerdict(for path: String, rules: [CleanRule], home: String, now: Date,
                                  installed: () -> Set<String>?) -> DeleteOutcome? {
        guard adminRule(for: path, rules: rules, home: home) != nil else { return .refused(.unsafePath) }
        let fd: Int32
        switch Deleter.openParent(of: path) {
        case .failure(let early): return early.outcome
        case .success(let opened): fd = opened
        }
        defer { close(fd) }
        return smartCleanVerdict(for: path, parentFD: fd, rules: rules, home: home, now: now, installed: installed)
    }

    /// `smartCleanVerdict(for:rules:home:now:)` for `path` whose parent is
    /// open as `parentFD`: the catalog guard (`catalogTarget`), then the age,
    /// measured relative to `parentFD`, the fd the protection check and the
    /// delete use too.
    static func smartCleanVerdict(for path: String, parentFD: Int32, rules: [CleanRule], home: String,
                                  now: Date, installed: () -> Set<String>?) -> DeleteOutcome? {
        guard let (rule, name) = catalogTarget(for: path, parentFD: parentFD, rules: rules, home: home,
                                               installed: installed),
              let minDays = rule.ageTiers.map(\.days).min() else {
            return .refused(.unsafePath)
        }
        let m: Measurement
        do throws(MeasureError) {
            m = try Measurer.measure(name: name, inParent: parentFD, context: MeasureContext())
        } catch {
            switch error {
            case .notFound: return .missing
            case .unreadable, .timedOut: return .failed("Couldn't check the item's age")
            }
        }
        if now.timeIntervalSince(m.newest) < Double(minDays) * 86400 {
            return .changedSinceScan(size: m.size, fileCount: m.fileCount)
        }
        return nil
    }

    /// Root's catalog guard for `path` whose parent is open as `parentFD`,
    /// shared by `--delete` (Smart Clean) and `smart-measure`. Returns the rule
    /// and the item's name only when all of these hold, else nil (refuse):
    /// - the first rule claiming `path` `requiresAdmin`, and the parent's real
    ///   location (`F_GETPATH`) plus the name is claimed by that same rule (a
    ///   symlinked ancestor can only deny);
    /// - for a `fileFilter` rule, the entry is a regular file;
    /// - for a `.launchdOrphan` rule, the item, read through `parentFD`, is
    ///   still an orphan (`CleanEngine.orphanCheck`): a launchd plist's absolute
    ///   program is missing, or none of a helper's owning apps is in
    ///   `installed()` (lowercased; nil means refuse).
    static func catalogTarget(for path: String, parentFD: Int32, rules: [CleanRule], home: String,
                              installed: () -> Set<String>?) -> (rule: CleanRule, name: String)? {
        guard let rule = adminRule(for: path, rules: rules, home: home),
              let (name, resolved) = resolvedPath(of: path, parentFD: parentFD),
              adminRule(for: resolved, rules: rules, home: home)?.id == rule.id else { return nil }
        if rule.fileFilter != nil {
            var st = stat()
            guard fstatat(parentFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        }
        if case .launchdOrphan = rule.special {
            let isPlist = name.hasSuffix(".plist")
            guard let data = readRegularEntry(name, inParent: parentFD, maxSize: isPlist ? 1 << 20 : 64 << 20),
                  case .orphan = CleanEngine.orphanCheck(isPlist: isPlist, data: data, installed: isPlist ? nil : installed())
            else { return nil }
        }
        return (rule, name)
    }

    /// The contents of regular file `name` in directory `parentFD`, opened
    /// without following a symlink; nil if it isn't one, can't be read, or is
    /// larger than `maxSize` bytes.
    static func readRegularEntry(_ name: String, inParent parentFD: Int32, maxSize: Int) -> Data? {
        try? PlistReader.readRegularFile(name: name, inDirectory: parentFD, maxSize: maxSize).get()
    }

    /// The system search roots for root's installed-apps set. `/Applications`
    /// comes first: if it can't be read, the set is nil (refuse).
    static let systemAppRoots = ["/Applications", "/System/Applications", "/opt/homebrew/Caskroom", "/usr/local/Caskroom"]

    /// Root's installed-apps set for the helper orphan test: the `.app`
    /// bundles on disk (no running-app or LaunchServices extras), lowercased.
    /// It never depends on the app-supplied `home`: every user's
    /// `<usersDir>/*/Applications` (and `Applications/Setapp`) is searched
    /// after `systemRoots`, with `InstalledApps` `.user` trust (no symlinks
    /// followed, unreadable apps skipped). A user folder that can't be opened
    /// or walked is skipped. nil if `systemRoots[0]` or `usersDir` can't be
    /// listed, or anything inside a system root can't be read.
    static func installedBundleIDs(systemRoots: [String] = systemAppRoots, usersDir: String = "/Users") -> Set<String>? {
        guard case .success(let users) = CleanEngine.list(usersDir) else { return nil }
        var userRoots: [String] = []
        for user in users.sorted() where !user.hasPrefix(".") {
            let apps = (usersDir as NSString).appendingPathComponent(user) + "/Applications"
            for root in [apps, apps + "/Setapp"] {
                let fd = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                if fd >= 0 { close(fd); userRoots.append(root) }
            }
        }
        guard var ids = InstalledApps.bundleIDs(searchRoots: systemRoots, extra: []) else { return nil }
        for root in userRoots {
            ids.formUnion(InstalledApps.apps(searchRoots: [root], trust: .user)?.map(\.bundleID) ?? [])
        }
        return Set(ids.map { $0.lowercased() })
    }

    /// The first rule in `rules` claiming `path`, if it needs administrator rights.
    static func adminRule(for path: String, rules: [CleanRule], home: String) -> CleanRule? {
        guard let rule = CleanEngine.rule(matching: path, in: rules, home: home), rule.requiresAdmin else { return nil }
        return rule
    }

    /// The last component of `path` and `<real location of parentFD>/<name>`.
    static func resolvedPath(of path: String, parentFD: Int32) -> (name: String, resolved: String)? {
        guard let (_, nameBytes) = Deleter.split(path) else { return nil }
        let name = String(decoding: nameBytes.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(parentFD, F_GETPATH, &buffer) != -1 else { return nil }
        let parent = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return (name, parent.hasSuffix("/") ? parent + name : parent + "/" + name)
    }

    /// The protection verdict for `path` whose parent is open as `parentFD`.
    ///
    /// The requested path's own verdict comes first. Then the parent's real
    /// location is read back with `F_GETPATH`, and `<resolved parent>/<name>`
    /// must not be refused either, so a path through a symlinked ancestor
    /// can't reach a protected item.
    public static func resolvedRefusal(for path: String, parentFD: Int32, context: ProtectionContext,
                                       in env: ProtectionEnvironment) -> Refusal? {
        if let refusal = ProtectionRules.refusal(for: path, context: context, in: env) { return refusal }
        guard let (_, full) = resolvedPath(of: path, parentFD: parentFD) else { return .unsafePath }
        return ProtectionRules.refusal(for: full, context: context, in: env)
    }

    private struct Line: Codable {
        let path: String
        let outcome: DeleteOutcome
    }

    static func json(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding these plain value types can't fail.
        return String(decoding: try! encoder.encode(value), as: UTF8.self)
    }
}
