import Foundation
import MacleanCore
import Observation

/// The app's scan sessions keyed by canonical path, plus which result the
/// window is showing.
@MainActor @Observable final class SessionRegistry {
    private var sessions: [String: ScanSession] = [:]
    /// The session whose result the window shows; nil shows the start screen.
    var presented: ScanSession?

    func session(for path: String) -> ScanSession? {
        sessions[Self.canonical(path)]
    }

    /// Starts a fresh scan of `path`, replacing any earlier result for it. A
    /// scan of that path already in progress is returned as is (its data is
    /// fresh anyway). `expected` is the byte count progress is measured
    /// against (a volume's used bytes), nil for indeterminate progress.
    @discardableResult
    func startScan(path: String, expected: Int64? = nil) -> ScanSession {
        let key = Self.canonical(path)
        if let existing = sessions[key], existing.isScanning { return existing }
        let session = ScanSession(rootPath: key, expected: expected)
        session.onFinish = { [weak self] finished in
            // Open the result when the window is on the start screen.
            guard let self, self.presented == nil, self.sessions[finished.rootPath] === finished else { return }
            self.presented = finished
        }
        if presented?.rootPath == key { presented = nil }
        sessions[key] = session
        session.start()
        return session
    }

    /// Forgets the in-memory result for `path`, cancelling a scan in progress.
    func forget(path: String) {
        let key = Self.canonical(path)
        guard let session = sessions.removeValue(forKey: key) else { return }
        session.cancel()
        if presented === session { presented = nil }
    }

    private static func canonical(_ path: String) -> String {
        ScanBoundary.canonicalPath(path) ?? path
    }
}
