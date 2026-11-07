import Foundation
import MacleanCore
import Observation

/// The app's scan sessions keyed by canonical path, plus which result the
/// window is showing.
@MainActor @Observable final class SessionRegistry {
    private var sessions: [String: ScanSession] = [:]
    /// Canonical paths in the order their sessions were started.
    private var order: [String] = []
    /// The session whose result the window shows; nil shows the start screen.
    var presented: ScanSession?
    /// The most recent user-started scan: the only one whose finish may open
    /// its result by itself.
    @ObservationIgnored private var latest: ScanSession?

    /// This session's scans, oldest first.
    var all: [ScanSession] { order.compactMap { sessions[$0] } }

    /// Looks up `path` after canonicalizing it (a `realpath` call).
    func session(for path: String) -> ScanSession? {
        sessions[Self.canonical(path)]
    }

    /// Looks up an already canonical path; cheap enough for view bodies.
    func session(canonical path: String) -> ScanSession? {
        sessions[path]
    }

    /// Starts a fresh scan of `path` (user-started: Scan, Scan Folder…,
    /// drops), replacing any earlier result for it. A scan of that path
    /// already in progress is kept (its data is fresh anyway). The window
    /// returns to the start screen so the row's progress shows, and the result
    /// opens when this scan finishes unless another scan was started since.
    /// `expected` is the byte count progress is measured against (a volume's
    /// used bytes), nil for indeterminate progress.
    @discardableResult
    func startScan(path: String, expected: Int64? = nil) -> ScanSession {
        let key = Self.canonical(path)
        presented = nil
        if let existing = sessions[key], existing.isScanning {
            latest = existing
            return existing
        }
        let session = ScanSession(rootPath: key, expected: expected)
        session.onFinish = { [weak self] in self?.finished($0) }
        if sessions[key] == nil { order.append(key) }
        sessions[key] = session
        latest = session
        session.start()
        return session
    }

    /// Rescans the session for `path` (canonical) in full, as a user-started scan.
    func rescan(canonical path: String) {
        guard let session = sessions[path], !session.isScanning else { return }
        presented = nil
        latest = session
        session.rescan()
    }

    /// Forgets the in-memory result for `path`, cancelling a scan in progress.
    func forget(path: String) {
        let key = sessions[path] != nil ? path : Self.canonical(path)
        guard let session = sessions.removeValue(forKey: key) else { return }
        order.removeAll { $0 == key }
        session.cancel()
        if presented === session { presented = nil }
        if latest === session { latest = nil }
    }

    private func finished(_ session: ScanSession) {
        guard latest === session else { return }
        latest = nil
        // Don't take over a result the user opened meanwhile.
        if presented == nil, sessions[session.rootPath] === session { presented = session }
    }

    private static func canonical(_ path: String) -> String {
        ScanBoundary.canonicalPath(path) ?? path
    }
}
