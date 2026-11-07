import Foundation

protocol AdminRunning: Sendable {
    /// Runs the bundled `maclean-scan` as root with `arguments` and returns
    /// its standard output. Throws `AdminRunnerError.cancelled` when the
    /// user cancels the administrator prompt.
    func run(_ arguments: [String]) async throws -> String
}

enum AdminRunnerError: Error, Equatable {
    case cancelled
    case failed(String)
}

/// Runs `Contents/MacOS/maclean-scan` with administrator privileges through
/// `osascript`. Every argument travels in argv and is quoted by AppleScript's
/// `quoted form of`: nothing is interpolated into the script text.
///
/// There is no timeout: the wait includes the password prompt, and killing
/// `osascript` wouldn't stop the root helper mid-delete anyway.
struct AdminRunner: AdminRunning {
    static let script = """
        on run argv
          set cmd to quoted form of (item 1 of argv)
          repeat with a in rest of argv
            set cmd to cmd & " " & quoted form of a
          end repeat
          do shell script cmd with administrator privileges
        end run
        """

    var helper: URL = Bundle.main.bundleURL.appending(path: "Contents/MacOS/maclean-scan")
    /// How long to keep reading the pipes after `osascript` exits (a stray
    /// process still holding them open must not block the result forever).
    static let drainGrace: Double = 2

    func run(_ arguments: [String]) async throws -> String {
        let helper = helper.path
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.runBlocking(helper: helper, arguments: arguments))
            }
        }
        return try result.get()
    }

    private static func runBlocking(helper: String, arguments: [String]) -> Result<String, AdminRunnerError> {
        guard FileManager.default.isExecutableFile(atPath: helper) else {
            return .failure(.failed("The administrator helper is missing from Maclean."))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // The script's lines, then argv: the helper's path first (an absolute
        // path, so osascript stops reading its own options there).
        process.arguments = script.split(separator: "\n").flatMap { ["-e", String($0)] } + [helper] + arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        // Drain both pipes concurrently so a full pipe can't stall the helper.
        let output = Drain(out.fileHandleForReading), errors = Drain(err.fileHandleForReading)
        do { try process.run() } catch { return .failure(.failed(error.localizedDescription)) }

        exited.wait()
        let stdout = output.text(grace: drainGrace), stderr = errors.text(grace: drainGrace)
        guard process.terminationStatus == 0 else {
            if process.terminationStatus == 1 && stderr.contains("-128") { return .failure(.cancelled) }
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.failed(message.isEmpty ? "The administrator helper failed." : message))
        }
        return .success(stdout)
    }

    /// Collects a pipe's data as it arrives, on a background queue.
    private final class Drain: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let done = DispatchSemaphore(value: 0)

        init(_ handle: FileHandle) {
            handle.readabilityHandler = { [self] h in
                let chunk = h.availableData
                if chunk.isEmpty {
                    h.readabilityHandler = nil
                    done.signal()
                } else {
                    lock.withLock { data.append(chunk) }
                }
            }
        }

        /// What was read, once the pipe hit its end or after `grace` seconds.
        func text(grace: Double) -> String {
            _ = done.wait(timeout: .now() + grace)
            return lock.withLock { String(decoding: data, as: UTF8.self) }
        }
    }
}
