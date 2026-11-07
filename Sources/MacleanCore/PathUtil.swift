import Foundation

public enum PathUtil {
    /// Whether `path` is `root` or lies below it, compared by whole path
    /// components. `"/"` contains everything.
    public static func isInside(_ path: String, orEqualTo root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
