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
    /// Sessions whose finished result opens in its own window (⌥-click Scan).
    @ObservationIgnored private var newWindowSessions: Set<ObjectIdentifier> = []
    /// Called when the latest user-started scan finishes, with whether it
    /// asked for its own window; nil falls back to presenting it here.
    @ObservationIgnored var onFinish: ((ScanSession, Bool) -> Void)?
    /// The session the main window showed when it was rescanned; it returns
    /// there when the rescan finishes.
    @ObservationIgnored private var resume: ScanSession?
    /// Called when a user-started fresh scan begins.
    @ObservationIgnored var onUserScan: (() -> Void)?
    /// Called after a session is forgotten, so views holding its result let go.
    @ObservationIgnored var onForget: ((ScanSession) -> Void)?

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
    /// used bytes), nil for indeterminate progress. `newWindow` (⌥-click)
    /// opens the finished result in its own window.
    @discardableResult
    func startScan(path: String, expected: Int64? = nil, newWindow: Bool = false) -> ScanSession {
        let key = Self.canonical(path)
        // A delete on this path's result must finish (or be cancelled) first.
        if let existing = sessions[key], existing.isDeleting { return existing }
        presented = nil
        resume = nil
        defer { onUserScan?() }
        if let existing = sessions[key], existing.isScanning {
            latest = existing
            if newWindow { newWindowSessions.insert(ObjectIdentifier(existing)) }
            return existing
        }
        let session = ScanSession(rootPath: key, expected: expected)
        session.onFinish = { [weak self] in self?.finished($0) }
        if sessions[key] == nil { order.append(key) }
        sessions[key] = session
        latest = session
        if newWindow { newWindowSessions.insert(ObjectIdentifier(session)) }
        session.start()
        return session
    }

    /// Rescans the session for `path` (canonical) in full, as a user-started
    /// scan. The main window returns to the start screen (to show progress)
    /// only if it shows this session; other windows on it keep their result
    /// up with a "Rescanning…" banner and remap when it finishes.
    func rescan(canonical path: String) {
        guard let session = sessions[path], !session.isScanning, !session.isDeleting else { return }
        if presented === session {
            presented = nil
            resume = session
        }
        latest = session
        newWindowSessions.remove(ObjectIdentifier(session))
        session.rescan()
    }

    /// Forgets the in-memory result for `path`, cancelling a scan in progress
    /// and clearing its collector (the caller confirms a non-empty one). A
    /// delete counting down is cancelled (nothing deleted) and a delete
    /// summary dismissed; while a delete runs, nothing happens and false is
    /// returned (the delete must finish where it can be seen).
    @discardableResult
    func forget(path: String) -> Bool {
        let key = sessions[path] != nil ? path : Self.canonical(path)
        guard let session = sessions[key] else { return true }
        if session.isDeleting, let deletion = session.deletionController, !deletion.abandonForForget() {
            return false
        }
        sessions[key] = nil
        order.removeAll { $0 == key }
        session.cancel()
        session.uncollectAll()
        if presented === session { presented = nil }
        if latest === session { latest = nil }
        if resume === session { resume = nil }
        newWindowSessions.remove(ObjectIdentifier(session))
        onForget?(session)
        return true
    }

    /// Spec §5.3: in every session whose tree holds a deleted request's path
    /// with the same inode and device, that node is marked removed, so the
    /// map shrinks without a rescan.
    func markRemoved(_ requests: [DeleteRequest]) {
        guard !requests.isEmpty else { return }
        for session in all {
            guard let tree = session.view?.tree else { continue }
            let ids = requests.compactMap { r -> NodeID? in
                guard let id = tree.node(atPath: r.path), tree.inode(of: id) == r.inode,
                      tree.device(of: id) == r.device else { return nil }
                return id
            }
            if !ids.isEmpty { session.markDeleted(ids) }
        }
    }

    private func finished(_ session: ScanSession) {
        guard latest === session else { return }
        latest = nil
        let newWindow = newWindowSessions.remove(ObjectIdentifier(session)) != nil
        guard sessions[session.rootPath] === session else { return }
        if resume === session {
            resume = nil
            if presented == nil { presented = session }
        }
        if let onFinish {
            onFinish(session, newWindow)
        } else if presented == nil {
            // Don't take over a result the user opened meanwhile.
            presented = session
        }
    }

    private static func canonical(_ path: String) -> String {
        ScanBoundary.canonicalPath(path) ?? path
    }
}
