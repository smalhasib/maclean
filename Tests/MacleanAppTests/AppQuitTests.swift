import Foundation
import Testing
@testable import Maclean

/// Quitting while one of the app's own sheets is up (the update sheet shows "Installing…"
/// while the relaunch quits the old copy). AppKit refuses to quit under a SwiftUI sheet,
/// so the sheets must go first.
@Suite(.serialized) struct AppQuitTests {
    /// Swaps the hooks for the test and puts the real ones back.
    @MainActor private func withHooks(dismiss: @escaping () -> Void, sheetsUp: @escaping () -> Bool,
                                      terminate: @escaping () -> Void, _ body: () async -> Void) async {
        let saved = (AppQuit.dismissSheets, AppQuit.sheetsAreUp, AppQuit.terminate)
        AppQuit.dismissSheets = dismiss
        AppQuit.sheetsAreUp = sheetsUp
        AppQuit.terminate = terminate
        await body()
        (AppQuit.dismissSheets, AppQuit.sheetsAreUp, AppQuit.terminate) = saved
    }

    @MainActor private func wait(seconds: Double, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test @MainActor func dismissesSheetsThenTerminatesOnceTheyAreGone() async {
        var calls: [String] = []
        var polls = 0
        await withHooks(dismiss: { calls.append("dismiss") },
                        sheetsUp: { polls += 1; return polls < 4 },   // SwiftUI takes a few turns to remove it
                        terminate: { calls.append("terminate") }) {
            AppQuit.quit()
            #expect(calls == ["dismiss"])   // asked to quit, but the sheet is still up
            await wait(seconds: 3) { calls.contains("terminate") }
        }
        #expect(calls == ["dismiss", "terminate"])
        #expect(polls >= 4)
    }

    @Test @MainActor func terminatesStraightAwayWithNoSheet() async {
        var calls: [String] = []
        await withHooks(dismiss: { calls.append("dismiss") }, sheetsUp: { false },
                        terminate: { calls.append("terminate") }) {
            AppQuit.quit()
            #expect(calls == ["dismiss", "terminate"])
        }
    }

    @Test @MainActor func stillAsksToTerminateWhenASheetWillNotGo() async {
        // A sheet the app doesn't own: the quit is attempted (and refused by AppKit), not abandoned.
        var terminated = false
        await withHooks(dismiss: {}, sheetsUp: { true }, terminate: { terminated = true }) {
            AppQuit.quit()
            await wait(seconds: 3) { terminated }
        }
        #expect(terminated)
    }
}
