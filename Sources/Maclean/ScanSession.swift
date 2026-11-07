import Foundation
import MacleanCore
import MacleanKit
import Observation

/// One scan of one root path: owns the scan task, its progress, the result
/// tree and the navigation history (stored as paths, so it survives rescans).
@MainActor @Observable final class ScanSession: Identifiable {
    enum State {
        case scanning(bytes: Int64, expected: Int64?)
        case finished(FileTree)
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let rootPath: String
    /// Bytes the scan is measured against (a volume's used bytes); nil shows
    /// indeterminate progress.
    let expected: Int64?
    private(set) var state: State = .cancelled
    /// True between `cancel()` and the scan task actually ending.
    private(set) var isStopping = false
    /// Written back by the result window so a rescan can remap where it was.
    var history: NavigationHistory
    /// Called on the main actor each time a scan finishes successfully.
    var onFinish: ((ScanSession) -> Void)?

    @ObservationIgnored private var task: Task<Void, Never>?
    /// The last finished tree, restored if a rescan is cancelled.
    @ObservationIgnored private var previousTree: FileTree?

    init(rootPath: String, expected: Int64? = nil) {
        self.rootPath = rootPath
        self.expected = expected
        history = NavigationHistory(rootPath: rootPath)
    }

    var tree: FileTree? {
        if case .finished(let tree) = state { return tree }
        return nil
    }

    var isScanning: Bool {
        if case .scanning = state { return true }
        return false
    }

    func start() {
        guard task == nil else { return }
        if case .finished(let tree) = state { previousTree = tree }
        isStopping = false
        state = .scanning(bytes: 0, expected: expected)
        let path = rootPath
        // Strong captures: the session lives at least until its scan ends.
        task = Task {
            let result: Result<FileTree, any Error>
            do {
                let tree = try await Scanner.scan(path: path) { progress in
                    Task { @MainActor in self.report(bytes: progress.bytes) }
                }
                result = .success(tree)
            } catch {
                result = .failure(error)
            }
            self.finish(result)
        }
    }

    /// Requests cancellation; the state stays `.scanning` (shown as
    /// "Stopping…") until the scan task ends.
    func cancel() {
        guard let task, !isStopping else { return }
        isStopping = true
        task.cancel()
    }

    /// Rescans the root in full; the new tree replaces the old one and the
    /// history is remapped by path.
    func rescan() {
        guard task == nil else { return }
        start()
    }

    private func report(bytes: Int64) {
        guard task != nil, case .scanning = state else { return }
        state = .scanning(bytes: bytes, expected: expected)
    }

    private func finish(_ result: Result<FileTree, any Error>) {
        task = nil
        let wasStopping = isStopping
        isStopping = false
        switch result {
        case .success(let tree):
            previousTree = nil
            history.remap { tree.node(atPath: $0) != nil }
            state = .finished(tree)
            onFinish?(self)
        case .failure(let error):
            if error is CancellationError || wasStopping {
                if let previousTree {
                    state = .finished(previousTree)
                } else {
                    state = .cancelled
                }
            } else {
                state = .failed(Self.message(for: error))
            }
            previousTree = nil
        }
    }

    private static func message(for error: any Error) -> String {
        switch error as? ReadError {
        case .notFound: "This folder no longer exists"
        case .notDirectory: "This isn't a folder"
        default: "Couldn't read this folder"
        }
    }
}
