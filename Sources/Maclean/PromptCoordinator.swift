import Foundation
import Observation

/// Decides what is on screen above the start window, and when an administrator
/// dialog may appear (spec §6a.3): the Full Disk Access sheet first, then the
/// update sheet, then admin jobs one at a time, each waiting until nothing is
/// above it.
@MainActor @Observable final class PromptCoordinator {
    enum Sheet: Equatable {
        case fullDiskAccess(granted: Bool)
        case update
    }

    private(set) var sheet: Sheet? {
        // R11: the sheet lives on the main window, which may be closed (window
        // per scan): bring it back first, or the sheet is invisible and admin
        // jobs wait behind it forever.
        didSet { if let sheet, sheet != oldValue { onSheetRaised?() } }
    }
    /// The start-screen notice after "Continue without Full Disk Access".
    private(set) var showsAccessNotice = false
    /// Access turned on after the launch probe said no; the notice offers Relaunch.
    private(set) var accessGranted = false
    /// "Finish the current delete first." after Relaunch was refused during a run.
    private(set) var relaunchRefusal: String?

    /// Called whenever a sheet is raised; the app shows the main window (R11).
    @ObservationIgnored var onSheetRaised: (@MainActor () -> Void)?
    /// True while a delete or a Smart Clean clean runs; Relaunch is refused then.
    @ObservationIgnored var isBusy: @MainActor () -> Bool = { false }
    /// Quits and reopens the app (replaced in tests).
    @ObservationIgnored var relauncher: @MainActor () -> Void = { Relauncher.relaunch() }

    @ObservationIgnored private let hasAccess: () -> Bool
    @ObservationIgnored private var updatePending = false
    @ObservationIgnored private var accessPending = false
    @ObservationIgnored private var adminBusy = false
    @ObservationIgnored private var adminWaiters: [CheckedContinuation<Void, Never>] = []

    init(hasAccess: @escaping () -> Bool) {
        self.hasAccess = hasAccess
    }

    func launch() {
        if !hasAccess() { sheet = .fullDiskAccess(granted: false) }
    }

    func continueWithoutAccess() {
        showsAccessNotice = true
        closeSheet()
    }

    func reopenAccessSheet() {
        if sheet == nil { sheet = .fullDiskAccess(granted: accessGranted) } else if sheet == .update { accessPending = true }
    }

    /// Re-probes, for the return from System Settings. R10: only the access
    /// sheet itself switches to its granted state; otherwise just the flag is
    /// set and the start-screen notice offers Relaunch, so no sheet is ever
    /// raised over another view's sheet.
    func becameActive() {
        guard sheet == .fullDiskAccess(granted: false) || showsAccessNotice, !accessGranted, hasAccess() else { return }
        accessGranted = true
        if sheet == .fullDiskAccess(granted: false) { sheet = .fullDiskAccess(granted: true) }
    }

    /// Whether Full Disk Access is on now (granted since launch, or a fresh probe).
    func accessIsGranted() -> Bool {
        accessGranted || hasAccess()
    }

    /// Relaunch from the access sheet or a notice; refused while a delete or a
    /// Smart Clean clean runs.
    func relaunch() {
        if isBusy() {
            relaunchRefusal = UpdateController.busyMessage
            return
        }
        relaunchRefusal = nil
        relauncher()
    }

    func requestUpdateSheet() {
        if sheet == nil { sheet = .update } else if sheet != .update { updatePending = true }
    }

    /// Any dismissal (Escape, a click outside, the sheet's own buttons). Leaving
    /// the not-granted sheet without access is the same as Continue.
    func dismissSheet() {
        if sheet == .fullDiskAccess(granted: false) {
            continueWithoutAccess()
        } else {
            // "Later" on the granted sheet: the notice keeps offering Relaunch.
            if sheet == .fullDiskAccess(granted: true) { showsAccessNotice = true }
            closeSheet()
        }
    }

    /// Runs `job` once no sheet is up and no other admin job is running. The
    /// job shows the dialog (with `reason`), so the dialogs never overlap.
    /// Throws `CancellationError`, without running `job`, when the calling task
    /// was cancelled while it waited (a waiting task is only noticed once its
    /// turn comes, and it then passes the slot on).
    func admin<T>(_ reason: String, _ job: @escaping @MainActor () async -> T) async throws -> T {
        if adminBusy || sheet != nil || !adminWaiters.isEmpty {
            await withCheckedContinuation { adminWaiters.append($0) }
            // A sheet may have appeared between the hand-over and now: wait again, first in line.
            while sheet != nil, !Task.isCancelled {
                adminBusy = false
                await withCheckedContinuation { adminWaiters.insert($0, at: 0) }
            }
            if Task.isCancelled {
                adminBusy = false
                drainAdmin()
                throw CancellationError()
            }
        } else {
            adminBusy = true
        }
        let result = await job()
        adminBusy = false
        drainAdmin()
        return result
    }

    // MARK: - Helpers

    private func closeSheet() {
        relaunchRefusal = nil
        if updatePending {
            updatePending = false
            sheet = .update
        } else if accessPending {
            accessPending = false
            sheet = .fullDiskAccess(granted: accessGranted)
        } else {
            sheet = nil
        }
        drainAdmin()
    }

    /// Starts the next waiting job; it inherits the busy flag.
    private func drainAdmin() {
        guard !adminBusy, sheet == nil, !adminWaiters.isEmpty else { return }
        adminBusy = true
        adminWaiters.removeFirst().resume()
    }
}
