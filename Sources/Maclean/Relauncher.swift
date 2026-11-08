import AppKit

/// Opens a fresh instance of the app, then quits this one. macOS applies a
/// Full Disk Access grant only to a new process. Not unit tested: it quits.
enum Relauncher {
    @MainActor static func relaunch(bundleURL: URL = Bundle.main.bundleURL) {
        // Unbundled (`swift run`): there is no app to open, so just quit.
        guard bundleURL.pathExtension == "app" else {
            NSApp.terminate(nil)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The shell outlives this process; the pause lets this instance finish quitting.
        process.arguments = ["-c", "sleep 1; open -n \"$0\"", bundleURL.path]
        // Quit only if the new instance is on its way.
        do { try process.run() } catch { return }
        NSApp.terminate(nil)
    }
}
