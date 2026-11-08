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

    /// Every `.app` up to depth 3, as (name without `.app`, bundle id); nil on a
    /// read error as for `bundleIDs`, or when there are no roots. Bundles aren't entered and symlinked
    /// folders aren't followed (a symlinked root is resolved first).
    public static func apps(searchRoots: [String]) -> [(name: String, bundleID: String)]? {
        var found: [(name: String, bundleID: String)] = []
        func walk(_ dir: String, depth: Int) -> Bool {
            let names: [String]
            switch CleanEngine.list(dir) {
            case .success(let n): names = n
            case .failure(let e): return e.code == .ENOENT
            }
            for name in names.sorted() where !name.hasPrefix(".") {
                let path = (dir as NSString).appendingPathComponent(name)
                if name.hasSuffix(".app") {
                    switch PlistReader.dictionary(atPath: (path as NSString).appendingPathComponent("Contents/Info.plist")) {
                    case .success(let info):
                        if let id = info["CFBundleIdentifier"] as? String { found.append((String(name.dropLast(4)), id)) }
                    case .failure(.missing): break
                    case .failure: return false
                    }
                } else if depth < 3 {
                    var st = stat()
                    if lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, !walk(path, depth: depth + 1) { return false }
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
            if !walk(real, depth: 1) { return nil }
        }
        return found
    }
}
