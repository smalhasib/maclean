import Foundation
import MacleanCore

/// Starred folders, persisted as paths plus bookmark data (no security
/// scope: the app is not sandboxed) so a moved folder can be followed.
@MainActor public final class StarredFolders {
    private struct Item: Codable, Sendable { var path: String; var bookmark: Data; var volume: String? }

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
        apply(Self.resolved(items, mounted: Set(mountPoints())))
    }

    /// `resolve()` with the bookmark and file-system work done off the main
    /// actor. Folders starred or unstarred meanwhile are kept as they are.
    @discardableResult
    public func resolveInBackground() async -> [String] {
        let snapshot = items
        let mounted = Set(mountPoints())
        let outcome = await Task.detached(priority: .utility) { Self.resolved(snapshot, mounted: mounted) }.value
        return apply(outcome)
    }

    /// Replaces each current item that was resolved (by its old path) with
    /// its outcome (nil drops it), then removes duplicate paths.
    private func apply(_ outcome: [(old: String, new: Item?)]) -> [String] {
        let byOld = Dictionary(outcome.map { ($0.old, $0.new) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        items = items.compactMap { item in
            let resolved: Item? = if let entry = byOld[item.path] { entry } else { item }
            guard let resolved, seen.insert(resolved.path).inserted else { return nil }
            return resolved
        }
        save()
        return paths
    }

    private nonisolated static func resolved(_ items: [Item], mounted: Set<String>) -> [(old: String, new: Item?)] {
        items.map { item in
            var stale = false
            var resolved = item
            if let url = try? URL(resolvingBookmarkData: item.bookmark, options: [.withoutUI, .withoutMounting],
                                  bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path) {
                resolved.path = canonical(url.path)
                if stale, let fresh = try? URL(fileURLWithPath: resolved.path).bookmarkData(options: []) {
                    resolved.bookmark = fresh
                }
                let parts = resolved.path.split(separator: "/")
                if parts.contains(".Trash") || parts.contains(".Trashes") { return (item.path, nil) }
            } else if let v = item.volume, v != "/", !mounted.contains(v) {
                // Volume offline: keep as is.
            } else {
                return (item.path, nil)
            }
            return (item.path, resolved)
        }
    }

    private func volume(of path: String) -> String {
        mountPoints().filter { $0 == "/" || path == $0 || path.hasPrefix($0 + "/") }
            .max { $0.count < $1.count } ?? "/"
    }

    private nonisolated static func canonical(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(items), forKey: key)
    }
}
