import Foundation
import Testing
@testable import Maclean

/// A flag the fake probe reads, flipped from the test.
private final class Access: @unchecked Sendable {
    var granted: Bool
    init(_ granted: Bool) { self.granted = granted }
}

@MainActor private func make(_ granted: Bool) -> (PromptCoordinator, Access) {
    let access = Access(granted)
    return (PromptCoordinator(hasAccess: { access.granted }), access)
}

/// Lets queued main-actor work run.
@MainActor private func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

@MainActor @Test func launchWithoutAccessShowsSheet() {
    let (coordinator, _) = make(false)
    coordinator.launch()
    #expect(coordinator.sheet == .fullDiskAccess(granted: false))
}

@MainActor @Test func launchWithAccessShowsNothing() {
    let (coordinator, _) = make(true)
    coordinator.launch()
    #expect(coordinator.sheet == nil)
    #expect(!coordinator.showsAccessNotice)
}

@MainActor @Test func continueShowsNotice() {
    let (coordinator, _) = make(false)
    coordinator.launch()
    coordinator.continueWithoutAccess()
    #expect(coordinator.sheet == nil)
    #expect(coordinator.showsAccessNotice)
    coordinator.reopenAccessSheet()
    #expect(coordinator.sheet == .fullDiskAccess(granted: false))
}

@MainActor @Test func grantNoticedOnActivation() {
    let (coordinator, access) = make(false)
    coordinator.launch()
    coordinator.becameActive()
    #expect(coordinator.sheet == .fullDiskAccess(granted: false))
    access.granted = true
    coordinator.becameActive()
    #expect(coordinator.sheet == .fullDiskAccess(granted: true))
}

@MainActor @Test func grantNoticedFromNoticeAfterContinue() {
    let (coordinator, access) = make(false)
    coordinator.launch()
    coordinator.continueWithoutAccess()
    access.granted = true
    coordinator.becameActive()
    #expect(coordinator.sheet == .fullDiskAccess(granted: true))
}

@MainActor @Test func activationWithAccessAndNothingShowingStaysQuiet() {
    let (coordinator, _) = make(true)
    coordinator.becameActive()
    #expect(coordinator.sheet == nil)
}

@MainActor @Test func updateSheetWaitsForAccessSheet() {
    let (coordinator, _) = make(false)
    coordinator.launch()
    coordinator.requestUpdateSheet()
    #expect(coordinator.sheet == .fullDiskAccess(granted: false))
    coordinator.continueWithoutAccess()
    #expect(coordinator.sheet == .update)
    coordinator.dismissSheet()
    #expect(coordinator.sheet == nil)
}

@MainActor @Test func updateSheetShowsAtOnceWhenFree() {
    let (coordinator, _) = make(true)
    coordinator.requestUpdateSheet()
    #expect(coordinator.sheet == .update)
}

@MainActor @Test func adminJobWaitsForSheetsAndRunsSerially() async throws {
    let (coordinator, _) = make(false)
    coordinator.launch()

    var log: [String] = []
    var running = 0
    var peak = 0
    var gates: [CheckedContinuation<Void, Never>] = []
    func job(_ name: String) -> @MainActor () async -> String {
        {
            running += 1
            peak = max(peak, running)
            log.append("start \(name)")
            await withCheckedContinuation { gates.append($0) }
            log.append("end \(name)")
            running -= 1
            return name
        }
    }

    let first = Task { try await coordinator.admin("r", job("a")) }
    let second = Task { try await coordinator.admin("r", job("b")) }
    await settle()
    #expect(log.isEmpty)   // the sheet is up

    coordinator.continueWithoutAccess()
    await settle()
    #expect(log == ["start a"])   // b waits for a

    gates.removeFirst().resume()
    await settle()
    #expect(log == ["start a", "end a", "start b"])

    gates.removeFirst().resume()
    #expect(try await first.value == "a")
    #expect(try await second.value == "b")
    #expect(peak == 1)
}

@MainActor @Test func adminJobWaitsForAnUpdateSheetToo() async {
    let (coordinator, _) = make(true)
    coordinator.requestUpdateSheet()
    var ran = false
    let task = Task { try await coordinator.admin("r") { ran = true } }
    await settle()
    #expect(!ran)
    coordinator.dismissSheet()
    try? await task.value
    #expect(ran)
}

@MainActor @Test func dismissingNotGrantedSheetActsLikeContinue() {
    let (coordinator, _) = make(false)
    coordinator.launch()
    coordinator.dismissSheet()   // Escape or a click outside
    #expect(coordinator.sheet == nil)
    #expect(coordinator.showsAccessNotice)
}

@MainActor @Test func reopenWhileUpdateShowingQueuesAccessSheet() {
    let (coordinator, _) = make(false)
    coordinator.launch()
    coordinator.continueWithoutAccess()
    coordinator.requestUpdateSheet()
    coordinator.reopenAccessSheet()
    #expect(coordinator.sheet == .update)
    coordinator.dismissSheet()
    #expect(coordinator.sheet == .fullDiskAccess(granted: false))
}

@MainActor @Test func grantDuringUpdateSheetShowsGrantedAfterwards() {
    let (coordinator, access) = make(false)
    coordinator.launch()
    coordinator.continueWithoutAccess()
    coordinator.requestUpdateSheet()
    access.granted = true
    coordinator.becameActive()
    #expect(coordinator.sheet == .update)
    coordinator.dismissSheet()
    #expect(coordinator.sheet == .fullDiskAccess(granted: true))
}

@MainActor @Test func grantedSheetDismissedWithUpdatePendingShowsUpdate() {
    let (coordinator, access) = make(false)
    coordinator.launch()
    access.granted = true
    coordinator.becameActive()
    coordinator.requestUpdateSheet()
    #expect(coordinator.sheet == .fullDiskAccess(granted: true))
    coordinator.dismissSheet()
    #expect(coordinator.sheet == .update)
}

@MainActor @Test func cancelledWaitingJobSkipsItsWorkAndPassesTheSlotOn() async {
    let (coordinator, _) = make(false)
    coordinator.launch()
    var ran: [String] = []
    let cancelled = Task { try await coordinator.admin("r") { ran.append("a") } }
    let next = Task { try await coordinator.admin("r") { ran.append("b") } }
    await settle()
    cancelled.cancel()
    coordinator.continueWithoutAccess()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    try? await next.value
    #expect(ran == ["b"])
}

@MainActor @Test func jobWaitsAgainWhenASheetAppearsBeforeItRuns() async {
    let (coordinator, _) = make(false)
    coordinator.launch()
    var ran = false
    let task = Task { try await coordinator.admin("r") { ran = true } }
    await settle()
    coordinator.continueWithoutAccess()   // hands the slot over...
    coordinator.requestUpdateSheet()      // ...and a sheet appears before the job resumes
    await settle()
    #expect(!ran)
    coordinator.dismissSheet()
    try? await task.value
    #expect(ran)
}
