import Foundation
import os
import UniformTypeIdentifiers

/// Decides whether a directory is a package (shown by Finder as a single
/// file, e.g. `.app`), by its filename extension. Results are cached per
/// lowercased extension.
public enum PackageDetector {
    private static let cache = OSAllocatedUnfairLock(initialState: [String: Bool]())

    public static func isPackage(name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...].lowercased()
        guard !ext.isEmpty else { return false }
        if let hit = cache.withLock({ $0[ext] }) { return hit }
        // Look the extension up among directory types: the default (.data)
        // never resolves to a package type, and `conformingTo: .package`
        // would fabricate a dynamic package type for unknown extensions.
        let result = UTType(filenameExtension: ext, conformingTo: .directory)?.conforms(to: .package) ?? false
        cache.withLock { $0[ext] = result }
        return result
    }
}
