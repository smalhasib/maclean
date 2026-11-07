import Foundation

/// Starred folders, persisted as paths plus bookmark data (no security
/// scope: the app is not sandboxed) so a moved folder can be followed.
@MainActor public final class StarredFolders {
    private struct Item: Codable { var path: String; var bookmark: Data }

    private let defaults: UserDefaults
    private let key: String
    private var items: [Item]

    public var paths: [String] { items.map(\.path) }

    public init(defaults: UserDefaults, key: String = "starredFolders") {
        self.defaults = defaults
        self.key = key
        items = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? []
    }

    public func star(_ url: URL) {
        let path = url.path
        guard !items.contains(where: { $0.path == path }),
              let bookmark = try? url.bookmarkData(options: []) else { return }
        items.append(Item(path: path, bookmark: bookmark))
        save()
    }

    public func unstar(_ path: String) {
        items.removeAll { $0.path == path }
        save()
    }

    /// Re-resolves the bookmarks: moved folders get their new path, missing
    /// ones are dropped.
    @discardableResult
    public func resolve() -> [String] {
        items = items.compactMap { item in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: item.bookmark, options: [], bookmarkDataIsStale: &stale),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            var item = item
            item.path = url.path
            if stale, let fresh = try? url.bookmarkData(options: []) { item.bookmark = fresh }
            return item
        }
        save()
        return paths
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(items), forKey: key)
    }
}
