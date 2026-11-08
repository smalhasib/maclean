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
    /// Missing roots are passed over; nil if the first root can't be listed.
    public static func bundleIDs(searchRoots: [String], extra: Set<String>) -> Set<String>? {
        guard let first = searchRoots.first,
              (try? FileManager.default.contentsOfDirectory(atPath: first)) != nil else { return nil }
        return Set(apps(searchRoots: searchRoots).map(\.bundleID)).union(extra)
    }

    /// Every `.app` up to depth 3, as (name without `.app`, bundle id).
    /// Bundles aren't entered and symlinked folders aren't followed.
    public static func apps(searchRoots: [String]) -> [(name: String, bundleID: String)] {
        var found: [(name: String, bundleID: String)] = []
        func walk(_ dir: String, depth: Int) {
            guard depth <= 3, let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
            for name in names where !name.hasPrefix(".") {
                let path = (dir as NSString).appendingPathComponent(name)
                if name.hasSuffix(".app") {
                    if let id = bundleID(ofBundle: path) { found.append((String(name.dropLast(4)), id)) }
                } else if depth < 3 {
                    var st = stat()
                    if lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR { walk(path, depth: depth + 1) }
                }
            }
        }
        for root in searchRoots { walk(root, depth: 1) }
        return found
    }

    /// `CFBundleIdentifier` from a bundle's `Contents/Info.plist`.
    public static func bundleID(ofBundle path: String) -> String? {
        let plist = (path as NSString).appendingPathComponent("Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return dict["CFBundleIdentifier"] as? String
    }
}
