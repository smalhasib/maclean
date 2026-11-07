import Foundation
import MacleanCore

/// Back/forward stack of absolute paths (paths, not node ids, so a rescan can remap it).
public struct NavigationHistory: Sendable, Equatable {
    public private(set) var current: String
    private let rootPath: String
    private var backStack: [String] = []
    private var forwardStack: [String] = []

    public init(rootPath: String) { self.rootPath = rootPath; current = rootPath }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    /// Navigate to `path`, dropping the forward stack. Visiting the current path is a no-op.
    public mutating func visit(_ path: String) {
        guard path != current else { return }
        backStack.append(current)
        current = path
        forwardStack.removeAll()
    }

    /// Replaces the current entry's path in place (stacks untouched), e.g. with
    /// its nearest surviving ancestor when the folder has vanished.
    public mutating func replaceCurrent(_ path: String) { current = path }

    public mutating func back() {
        guard let prev = backStack.popLast() else { return }
        forwardStack.append(current)
        current = prev
    }

    public mutating func forward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(current)
        current = next
    }

    /// The parent directory of `current`, or nil when `current` is the tree root.
    public func enclosing(rootPath: String) -> String? {
        guard current != rootPath, PathUtil.isInside(current, orEqualTo: rootPath) else { return nil }
        let parent = Self.parent(of: current)
        return PathUtil.isInside(parent, orEqualTo: rootPath) ? parent : nil
    }

    /// After a rescan: `current` becomes its nearest existing ancestor, never
    /// above the tree root (the root itself if even that is gone); missing
    /// back/forward entries are dropped and neighbouring duplicates collapsed.
    public mutating func remap(exists: (String) -> Bool) {
        var path = current
        while path != rootPath, !exists(path) {
            let parent = Self.parent(of: path)
            path = PathUtil.isInside(parent, orEqualTo: rootPath) ? parent : rootPath
        }
        current = path
        func clean(_ stack: [String]) -> [String] {
            var out: [String] = []
            var last = current
            for p in stack.reversed() where exists(p) && p != last {  // nearest-first
                out.append(p); last = p
            }
            return out.reversed()
        }
        // Back stack: nearest entry is last, so walk from the end towards the start.
        backStack = clean(backStack)
        forwardStack = clean(forwardStack)
    }

    private static func parent(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }
}
