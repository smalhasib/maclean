import Darwin
import Foundation

/// The installed-apps set for the removed-app leftover test (spec §6.6).
public enum InstalledApps {
    /// Where `.app` bundles are looked for. `/Applications` comes first: if it
    /// can't be read, the whole check fails.
    public static func defaultSearchRoots(home: String) -> [String] {
        ["/Applications", "/System/Applications", home + "/Applications", "/opt/homebrew/Caskroom",
         "/usr/local/Caskroom", home + "/Applications/Setapp"]
    }

    /// The bundle ids of `.app` bundles up to depth 3 under `searchRoots`,
    /// plus `extra` (running apps, LaunchServices ids, LaunchAgent labels).
    /// Absent roots (after the first) are passed over. nil when the first root
    /// can't be listed, or anything else can't be read: a folder (other than
    /// ENOENT) or an `.app`'s Info.plist (unreadable or unparsable).
    public static func bundleIDs(searchRoots: [String], extra: Set<String>) -> Set<String>? {
        apps(searchRoots: searchRoots).map { Set($0.map(\.bundleID)).union(extra) }
    }

    /// How far a search root is trusted.
    /// - `system`: root-controlled folders. A symlinked `.app` (Safari in
    ///   `/Applications`) is followed; anything unreadable fails the check.
    /// - `user`: folders a user controls (root's search of `/Users/*/Applications`).
    ///   No symlink is followed (`.app`, `Contents` or folders), and an app whose
    ///   `Info.plist` can't be read is passed over.
    /// In both, folders are entered with `O_NOFOLLOW` relative to their parent
    /// and `Info.plist` is read by `PlistReader` (no symlink, regular file, capped).
    public enum Trust: Sendable { case system, user }

    /// Every `.app` up to depth 3, as (name without `.app`, bundle id); nil on a
    /// read error as for `bundleIDs`, or when there are no roots. Bundles aren't
    /// entered and symlinked folders aren't followed (a symlinked root is resolved first).
    public static func apps(searchRoots: [String], trust: Trust = .system) -> [(name: String, bundleID: String)]? {
        var found: [(name: String, bundleID: String)] = []
        let noFollowApp = trust == .user ? O_NOFOLLOW : 0
        /// The app's `Contents/Info.plist`, opened relative to `dir`.
        func info(_ name: String, in dir: Int32) -> Result<[String: Any], PlistReader.Failure> {
            let app = openat(dir, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | noFollowApp)
            guard app >= 0 else { return .failure(errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable) }
            defer { close(app) }
            let contents = openat(app, "Contents", O_RDONLY | O_DIRECTORY | O_CLOEXEC | noFollowApp)
            guard contents >= 0 else { return .failure(errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable) }
            defer { close(contents) }
            return PlistReader.dictionary(name: "Info.plist", inDirectory: contents)
        }
        func walk(_ dir: Int32, depth: Int) -> Bool {
            guard let names = list(dir) else { return false }
            for name in names.sorted() where !name.hasPrefix(".") {
                if name.hasSuffix(".app") {
                    switch info(name, in: dir) {
                    case .success(let info):
                        if let id = info["CFBundleIdentifier"] as? String { found.append((String(name.dropLast(4)), id)) }
                    case .failure(.missing): break
                    case .failure: if trust == .system { return false }
                    }
                } else if depth < 3 {
                    let sub = openat(dir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    if sub < 0 {
                        if errno == ENOENT || errno == ENOTDIR || errno == ELOOP { continue }  // gone, a file, or a symlink
                        return false
                    }
                    defer { close(sub) }
                    if !walk(sub, depth: depth + 1) { return false }
                }
            }
            return true
        }
        guard !searchRoots.isEmpty else { return nil }
        for (i, root) in searchRoots.enumerated() {
            guard let resolved = realpath(root, nil) else {
                let missing = errno == ENOENT || errno == ENOTDIR
                if missing && i > 0 { continue } else { return nil }
            }
            let real = String(cString: resolved)
            free(resolved)
            let fd = open(real, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            if !walk(fd, depth: 1) { return nil }
        }
        return found
    }

    /// The entry names of directory `fd` (without `.` and `..`), or nil.
    private static func list(_ fd: Int32) -> [String]? {
        let copy = dup(fd)
        guard copy >= 0 else { return nil }
        guard let d = fdopendir(copy) else { close(copy); return nil }
        defer { closedir(d) }
        rewinddir(d)
        var names: [String] = []
        errno = 0
        while let entry = readdir(d) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return errno == 0 ? names : nil
    }
}
