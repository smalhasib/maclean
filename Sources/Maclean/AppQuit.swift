import AppKit

/// Quits the app even while one of its own SwiftUI sheets is up. A sheet makes
/// AppKit refuse every quit (⌘Q, the Quit Apple Event from System Settings'
/// "Quit & Reopen", `NSApp.terminate`), and only the state that owns the sheet
/// can remove it. So: drop the sheets, wait for SwiftUI to take them down, quit.
/// Without it, an update's relaunch started the new copy but left the old one
/// running under its "Installing…" sheet.
@MainActor enum AppQuit {
    /// Drops the app's own sheets (set at launch to the prompt coordinator's).
    static var dismissSheets: () -> Void = {}
    static var sheetsAreUp: () -> Bool = { NSApp.windows.contains { $0.attachedSheet != nil } }
    static var terminate: () -> Void = { NSApp.terminate(nil) }

    static func quit() {
        dismissSheets()
        terminateWhenSheetsAreGone(attempt: 0)
    }

    private static func terminateWhenSheetsAreGone(attempt: Int) {
        // ponytail: ~1 s of polling; a sheet we don't own stays and the quit is refused as before.
        guard sheetsAreUp(), attempt < 20 else { terminate(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { terminateWhenSheetsAreGone(attempt: attempt + 1) }
    }
}
