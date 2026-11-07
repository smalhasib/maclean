import Foundation
@testable import MacleanCore

/// A uniquely named scratch directory for tests. Everything inside it is
/// removed when the instance is deallocated, after restoring permissions so
/// that `chmod 000` directories can be deleted too.
///
/// Keep the instance alive for as long as the directory is used, e.g. with
/// `defer { withExtendedLifetime(t) {} }`.
final class TempDir {
    let path: String

    init() {
        // Canonical (realpath) form, matching the scanner's rootPath: unlike
        // `resolvingSymlinksInPath`, it keeps the `/private` prefix.
        let base = ScanBoundary.canonicalPath(FileManager.default.temporaryDirectory.path)!
        path = (base as NSString).appendingPathComponent("maclean-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    }

    deinit {
        Self.restorePermissions(path)
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Absolute path of `relative` inside the temp dir.
    func url(_ relative: String) -> String {
        (path as NSString).appendingPathComponent(relative)
    }

    /// Creates a regular file of `bytes` zero bytes, creating parent directories as needed.
    func file(_ relative: String, bytes: Int = 0) {
        let full = url(relative)
        try! FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: full, contents: Data(count: bytes)) else {
            fatalError("TempDir: cannot create file \(full)")
        }
    }

    /// Creates a directory (and any missing parents).
    func dir(_ relative: String) {
        try! FileManager.default.createDirectory(atPath: url(relative), withIntermediateDirectories: true)
    }

    /// Creates a symbolic link at `relative` whose target is `target` verbatim (may be relative).
    func symlink(_ relative: String, to target: String) {
        try! FileManager.default.createSymbolicLink(atPath: url(relative), withDestinationPath: target)
    }

    /// Creates a hard link at `relative` to the existing item at `existing` (both relative to the temp dir).
    func hardlink(_ relative: String, to existing: String) {
        try! FileManager.default.linkItem(atPath: url(existing), toPath: url(relative))
    }

    /// Sets POSIX permissions on `relative`.
    func chmod(_ relative: String, _ mode: mode_t) {
        guard Darwin.chmod(url(relative), mode) == 0 else {
            fatalError("TempDir: chmod failed for \(relative): errno \(errno)")
        }
    }

    private static func restorePermissions(_ dir: String) {
        var st = stat()
        guard lstat(dir, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return }
        _ = Darwin.chmod(dir, 0o700)
        for child in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
            restorePermissions((dir as NSString).appendingPathComponent(child))
        }
    }
}
