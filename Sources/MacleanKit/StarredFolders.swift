import Foundation
import MacleanCore

/// Starred folders, persisted as paths plus bookmark data (no security
/// scope: the app is not sandboxed) so a moved folder can be followed.
@MainActor public final class StarredFolders {
    private struct Item: Codable { var path: String; var bookmark: Data; var volume: String? }

    private let defaults: UserDefaults
    private let key: String
    private let mountPoints: @MainActor () -> [String]
    private var items: [Item]

    public var paths: [String] { items.map(\.path) }

    /// `mountPoints` lists the currently mounted volumes' paths; injectable so
    /// tests stay hermetic.
    public init(defaults: UserDefaults, key: String = "starredFolders",
                mountPoints: @escaping @MainActor () -> [String] = { ScanBoundary.mounts().map(\.path) }) {
        self.defaults = defaults
        self.key = key
        self.mountPoints = mountPoints
        items = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? []
    }

    public func star(_ url: URL) {
        let path = Self.canonical(url.path)
        guard !items.contains(where: { $0.path == path }),
              let bookmark = try? URL(fileURLWithPath: path).bookmarkData(options: []) else { return }
        items.append(Item(path: path, bookmark: bookmark, volume: volume(of: path)))
        save()
    }

    public func unstar(_ path: String) {
        let canonical = Self.canonical(path)
        items.removeAll { $0.path == path || $0.path == canonical }
        save()
    }

    /// Re-resolves the bookmarks: moved folders get their new path; folders
    /// that are gone (volume mounted) or in the Trash are dropped; folders on
    /// an unmounted volume are kept unchanged until it returns.
    @discardableResult
    public func resolve() -> [String] {
        let mounted = Set(mountPoints())
        var seen = Set<String>()
        items = items.compactMap { item in
            var stale = false
            var resolved = item
            if let url = try? URL(resolvingBookmarkData: item.bookmark, options: [.withoutUI, .withoutMounting],
                                  bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path) {
                resolved.path = Self.canonical(url.path)
                if stale, let fresh = try? URL(fileURLWithPath: resolved.path).bookmarkData(options: []) {
                    resolved.bookmark = fresh
                }
                let parts = resolved.path.split(separator: "/")
                if parts.contains(".Trash") || parts.contains(".Trashes") { return nil }
            } else if let v = item.volume, v != "/", !mounted.contains(v) {
                // Volume offline: keep as is.
            } else {
                return nil
            }
            return seen.insert(resolved.path).inserted ? resolved : nil
        }
        save()
        return paths
    }

    private func volume(of path: String) -> String {
        mountPoints().filter { $0 == "/" || path == $0 || path.hasPrefix($0 + "/") }
            .max { $0.count < $1.count } ?? "/"
    }

    private static func canonical(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(items), forKey: key)
    }
}
