import AppKit
import Foundation
import MacleanCore
import Observation

/// Auto-update (spec §5): checks GitHub's latest release, drives the update
/// sheet (through `PromptCoordinator`) and installs an accepted release.
@MainActor @Observable final class UpdateController {
    enum State: Equatable {
        case idle, checking, available(ReleaseInfo), upToDate, failed(String), downloading(Double), installing
    }

    /// What the sheet's main button does.
    enum InstallAction: Equatable {
        /// The user can replace the bundle: download, swap, relaunch.
        case install
        /// The bundle's folder needs an administrator (spec §6a.2).
        case installWithPassword
        /// Homebrew owns this copy: show `brew upgrade --cask maclean`.
        case brew
        /// Open the release page (after a cancelled password dialog, or no app bundle).
        case download
    }

    static let automaticKey = "update.automatic"
    static let lastCheckKey = "update.lastCheck"
    static let skippedVersionKey = "update.skippedVersion"
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/smalhasib/maclean/releases/latest")!
    static let latestReleasePage = URL(string: "https://github.com/smalhasib/maclean/releases/latest")!
    static let brewCommand = "brew upgrade --cask maclean"
    static let busyMessage = "Finish the current delete first."
    static let checkFailedMessage = "Couldn't check for updates. Check your internet connection and try again."

    private(set) var state: State = .idle
    /// A one-line reason shown in the sheet when Install can't start yet.
    private(set) var notice: String?
    /// The release the sheet offers (kept through download and failure).
    private(set) var release: ReleaseInfo?
    let currentVersion: String

    /// The running check, for tests and Cancel.
    @ObservationIgnored private(set) var checkTask: Task<Void, Never>?
    /// Which check `checkTask` is, so a cancelled one doesn't clear its successor.
    @ObservationIgnored private var checkGeneration = 0
    @ObservationIgnored private var downloadTask: Task<(Data, String)?, Never>?
    /// Which attempt `downloadTask` is, so a cancelled one that ends late changes nothing.
    @ObservationIgnored private var downloadGeneration = 0
    @ObservationIgnored private var presentTask: Task<Void, Never>?
    private var passwordCancelled = false

    @ObservationIgnored private let bundleURL: URL
    @ObservationIgnored private let fetch: (URL) async throws -> Data
    @ObservationIgnored private let download: (URL, @escaping @MainActor (Double) -> Void) async throws -> Data
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let coordinator: PromptCoordinator
    @ObservationIgnored private let installer: any UpdateInstalling
    @ObservationIgnored private let caskroomRoots: [String]
    @ObservationIgnored private let isWritable: (URL) -> Bool
    @ObservationIgnored private let isBusy: () -> Bool
    @ObservationIgnored private let canPresent: () -> Bool
    @ObservationIgnored private let presentPoll: Duration
    @ObservationIgnored private let installPrivileged: (Data, String, ReleaseInfo, URL) async throws -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let open: (URL) -> Void

    /// - Parameters:
    ///   - isBusy: true while a delete or Smart Clean run is in progress.
    ///   - canPresent: false while some other sheet is on screen; the update
    ///     sheet waits for it (a sheet set over another may never appear).
    ///   - installPrivileged: the administrator install (Task 6b); throws
    ///     `AdminRunnerError.cancelled` when the dialog is cancelled.
    init(currentVersion: String, bundleURL: URL, fetch: @escaping (URL) async throws -> Data,
         defaults: UserDefaults, coordinator: PromptCoordinator, installer: any UpdateInstalling,
         caskroomRoots: [String] = ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"],
         isWritable: @escaping (URL) -> Bool = { FileManager.default.isWritableFile(atPath: $0.path) },
         isBusy: @escaping () -> Bool = { false },
         canPresent: @escaping () -> Bool = { true },
         presentPoll: Duration = .milliseconds(500),
         installPrivileged: @escaping (Data, String, ReleaseInfo, URL) async throws -> Void = { _, _, _, _ in
             throw UpdateInstallError.privilegedUnavailable
         },
         download: ((URL, @escaping @MainActor (Double) -> Void) async throws -> Data)? = nil,
         now: @escaping () -> Date = Date.init,
         open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.currentVersion = currentVersion
        self.bundleURL = bundleURL
        self.fetch = fetch
        self.download = download ?? { url, _ in try await fetch(url) }
        self.defaults = defaults
        self.coordinator = coordinator
        self.installer = installer
        self.caskroomRoots = caskroomRoots
        self.isWritable = isWritable
        self.isBusy = isBusy
        self.canPresent = canPresent
        self.presentPoll = presentPoll
        self.installPrivileged = installPrivileged
        self.now = now
        self.open = open
    }

    var action: InstallAction {
        // Unbundled (`swift run`): there is no bundle to replace. Translocated (opened
        // from a quarantined download): a read-only copy that would vanish anyway.
        guard bundleURL.pathExtension == "app", !bundleURL.path.contains("/AppTranslocation/") else { return .download }
        if InstallSource.detect(bundlePath: bundleURL.path, caskroomRoots: caskroomRoots) == .homebrew { return .brew }
        if isWritable(bundleURL.deletingLastPathComponent()) { return .install }
        return passwordCancelled ? .download : .installWithPassword
    }

    /// The launch check: only when automatic checks are on, at most once a
    /// day, never for a skipped version, and silent on any failure.
    func checkAutomatically() {
        let automatic = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
        let last = defaults.object(forKey: Self.lastCheckKey) as? Date
        guard automatic, checkTask == nil, UpdateCheck.shouldCheck(lastCheck: last, now: now()) else { return }
        checkGeneration += 1
        let generation = checkGeneration
        checkTask = Task {
            defer { if checkGeneration == generation { checkTask = nil } }
            guard let latest = try? await latestRelease(), !Task.isCancelled else { return }
            guard isNewer(latest), defaults.string(forKey: Self.skippedVersionKey) != latest.version.description,
                  state == .idle else { return }
            offer(latest)
            requestSheet()
        }
    }

    /// Maclean › Check for Updates…: shows the sheet at once and always a result.
    func checkNow() {
        checkTask?.cancel()
        downloadTask?.cancel()
        notice = nil
        state = .checking
        requestSheet()
        checkGeneration += 1
        let generation = checkGeneration
        checkTask = Task {
            defer { if checkGeneration == generation { checkTask = nil } }
            do {
                let latest = try await latestRelease()
                guard !Task.isCancelled else { return }
                if isNewer(latest) { offer(latest) } else { state = .upToDate }
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(Self.checkFailedMessage)
            }
        }
    }

    func skip() {
        if let release { defaults.set(release.version.description, forKey: Self.skippedVersionKey) }
        close()
    }

    func later() { close() }

    /// Cancel while checking or downloading.
    func cancel() {
        if case .downloading = state, let release {
            downloadTask?.cancel()
            state = .available(release)
        } else {
            close()
        }
    }

    func install() async {
        guard let release else { return }
        notice = nil
        switch action {
        case .brew:
            return
        case .download:
            open(Self.releasePage(release))
            close()
            return
        case .install, .installWithPassword:
            break
        }
        guard !isBusy() else {
            notice = Self.busyMessage
            return
        }
        state = .downloading(0)
        downloadGeneration += 1
        let generation = downloadGeneration
        let task = Task { () -> (Data, String)? in
            do {
                let signature = String(decoding: try await fetch(release.signatureURL), as: UTF8.self)
                let zip = try await download(release.zipURL) { fraction in
                    guard generation == self.downloadGeneration, case .downloading = self.state else { return }
                    self.state = .downloading(fraction)
                }
                return Task.isCancelled ? nil : (zip, signature)
            } catch {
                return nil
            }
        }
        downloadTask = task
        let downloaded = await task.value
        // Cancelled (Cancel, Later, Check Now), possibly with a newer attempt running.
        guard generation == downloadGeneration, !task.isCancelled, case .downloading = state else { return }
        downloadTask = nil
        guard let (zip, signature) = downloaded else {
            state = .failed("The update couldn't be downloaded. Check your internet connection and try again.")
            return
        }
        // A delete may have started during the download.
        guard !isBusy() else {
            state = .available(release)
            notice = Self.busyMessage
            return
        }
        state = .installing
        do {
            if action == .install {
                try await installer.install(zip: zip, signature: signature, release: release, replacing: bundleURL)
            } else {
                try await installPrivileged(zip, signature, release, bundleURL)
            }
        } catch AdminRunnerError.cancelled {
            passwordCancelled = true
            state = .available(release)
        } catch let error as UpdateInstallError {
            state = .failed(error.message)
        } catch {
            state = .failed("The update couldn't be installed: \(error.localizedDescription)")
        }
    }

    /// Copies the Homebrew command for the sheet's Copy Command button.
    func copyBrewCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.brewCommand, forType: .string)
    }

    static func releasePage(_ release: ReleaseInfo) -> URL {
        URL(string: "https://github.com/smalhasib/maclean/releases/tag/v\(release.version)") ?? latestReleasePage
    }

    // MARK: - Helpers

    private func latestRelease() async throws -> ReleaseInfo {
        let latest = try ReleaseInfo.parse(try await fetch(Self.latestReleaseURL))
        defaults.set(now(), forKey: Self.lastCheckKey)
        return latest
    }

    private func isNewer(_ latest: ReleaseInfo) -> Bool {
        guard let current = SemanticVersion(currentVersion) else { return false }
        return latest.version > current
    }

    private func offer(_ latest: ReleaseInfo) {
        release = latest
        state = .available(latest)
    }

    /// Asks the coordinator for the sheet (spec §6a.3). Behind the
    /// coordinator's own sheet it queues there at once (Full Disk Access, then
    /// update, then admin); it polls only while another view's sheet is up.
    private func requestSheet() {
        guard coordinator.sheet != .update, presentTask == nil else { return }
        if coordinator.sheet != nil || canPresent() {
            coordinator.requestUpdateSheet()
            return
        }
        presentTask = Task {
            while coordinator.sheet == nil, !canPresent() {
                try? await Task.sleep(for: presentPoll)
                if Task.isCancelled { return }
            }
            presentTask = nil
            if state != .idle { coordinator.requestUpdateSheet() }
        }
    }

    private func close() {
        checkTask?.cancel()
        downloadTask?.cancel()
        presentTask?.cancel()
        presentTask = nil
        notice = nil
        state = .idle
        if coordinator.sheet == .update { coordinator.dismissSheet() }
    }
}

/// The live network calls: GitHub's API wants a User-Agent and its JSON media
/// type. Nothing personal is sent (ephemeral session: no cookies, no cache).
/// Bodies arrive in chunks and are capped, at 300 MB and at the announced size
/// plus 1 MB.
enum UpdateFetch {
    static let maxBytes: Int64 = 300 * 1024 * 1024
    static let slack: Int64 = 1024 * 1024

    static func request(_ url: URL, version: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Maclean/\(version)", forHTTPHeaderField: "User-Agent")
        if url.host == "api.github.com" {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    static func fetch(version: String) -> @Sendable (URL) async throws -> Data {
        { url in try await load(request(url, version: version), progress: nil) }
    }

    static func download(version: String) -> @Sendable (URL, @escaping @MainActor (Double) -> Void) async throws -> Data {
        { url, progress in try await load(request(url, version: version), progress: progress) }
    }

    /// The byte limit for a response announcing `expected` bytes (-1: unknown).
    static func limit(expected: Int64) -> Int64 {
        expected > 0 ? min(maxBytes, expected + slack) : maxBytes
    }

    static func load(_ request: URLRequest, progress: (@MainActor (Double) -> Void)?) async throws -> Data {
        let loader = Loader(progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: loader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                loader.start(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Collects one response's chunks; fails on a non-2xx status or an over-long body.
    private final class Loader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private let progress: (@MainActor (Double) -> Void)?
        private var continuation: CheckedContinuation<Data, Error>?
        private var data = Data()
        private var expected: Int64 = -1
        private var lastReported = 0
        private var failure: Error?

        init(progress: (@MainActor (Double) -> Void)?) { self.progress = progress }

        func start(_ continuation: CheckedContinuation<Data, Error>) {
            lock.withLock { self.continuation = continuation }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                lock.withLock { failure = URLError(.badServerResponse) }
                completionHandler(.cancel)
                return
            }
            let expected = response.expectedContentLength
            guard expected <= UpdateFetch.maxBytes else {
                lock.withLock { failure = URLError(.dataLengthExceedsMaximum) }
                completionHandler(.cancel)
                return
            }
            lock.withLock {
                self.expected = expected
                if expected > 0 { data.reserveCapacity(Int(expected)) }
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            let fraction: Double? = lock.withLock {
                data.append(chunk)
                if Int64(data.count) > UpdateFetch.limit(expected: expected) {
                    failure = URLError(.dataLengthExceedsMaximum)
                    return nil
                }
                guard expected > 0, data.count - lastReported >= 256 * 1024 else { return nil }
                lastReported = data.count
                return min(1, Double(data.count) / Double(expected))
            }
            if lock.withLock({ failure != nil }) {
                dataTask.cancel()
                return
            }
            if let fraction, let progress { Task { @MainActor in progress(fraction) } }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let (continuation, result): (CheckedContinuation<Data, Error>?, Result<Data, Error>) = lock.withLock {
                let c = self.continuation
                self.continuation = nil
                if let failure { return (c, .failure(failure)) }
                if let error { return (c, .failure(error)) }
                return (c, .success(data))
            }
            continuation?.resume(with: result)
        }
    }
}
