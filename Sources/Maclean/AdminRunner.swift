import Foundation

protocol AdminRunning: Sendable {
    /// Runs the bundled `maclean-scan` as root once per invocation (each one
    /// its argument list), all behind **one** administrator prompt showing
    /// `prompt`, and returns each invocation's standard output in order.
    /// Throws `AdminRunnerError.cancelled` when the user cancels the prompt.
    func run(_ invocations: [[String]], prompt: String) async throws -> [String]
}

extension AdminRunning {
    /// Runs one invocation behind its own prompt.
    func run(_ arguments: [String], prompt: String) async throws -> String {
        let outputs = try await run([arguments], prompt: prompt)
        guard outputs.count == 1 else { throw AdminRunnerError.failed(AdminRunner.malformed) }
        return outputs[0]
    }
}

enum AdminRunnerError: Error, Equatable {
    case cancelled
    case failed(String)
}

/// Runs `Contents/MacOS/maclean-scan` with administrator privileges through
/// in-process `NSAppleScript`, so the system dialog names Maclean and shows
/// Maclean's reason.
///
/// `NSAppleScript` has no argv, so every argument is embedded as an
/// AppleScript string literal (only `\` and `"` need escaping inside one) and
/// reaches the shell solely through `quoted form of`. Nothing is ever
/// interpolated into the shell command unquoted.
///
/// There is no timeout: the wait includes the password prompt, and abandoning
/// the script wouldn't stop the root helper mid-delete anyway.
struct AdminRunner: AdminRunning {
    var helper: URL = Bundle.main.bundleURL.appending(path: "Contents/MacOS/maclean-scan")

    static let malformed = "The administrator helper's output was malformed."

    /// `NSAppleScript` isn't thread-safe: every execution runs here, one at a
    /// time, off the main thread.
    private static let queue = DispatchQueue(label: "maclean.admin-runner", qos: .userInitiated)

    func run(_ invocations: [[String]], prompt: String) async throws -> [String] {
        guard !invocations.isEmpty else { return [] }
        let helper = helper.path
        guard FileManager.default.isExecutableFile(atPath: helper) else {
            throw AdminRunnerError.failed("The administrator helper is missing from Maclean.")
        }
        let (source, separator) = Self.script(helper: helper, invocations: invocations, prompt: prompt)
        let result: Result<String, AdminRunnerError> = await withCheckedContinuation { continuation in
            Self.queue.async {
                continuation.resume(returning: Self.execute(source))
            }
        }
        let outputs = Self.split(try result.get(), separator: separator)
        // The separator is random per call: an output holding it (an extra
        // piece) can only mean tampering, so nothing is trusted.
        guard outputs.count == invocations.count else { throw AdminRunnerError.failed(Self.malformed) }
        return outputs
    }

    /// Builds the AppleScript source and the separator line between outputs.
    /// Pure: every argument, the helper path, the separator and the prompt
    /// appear only as escaped string literals, and the shell sees each
    /// argument only through `quoted form of`.
    static func script(helper: String, invocations: [[String]], prompt: String) -> (source: String, separator: String) {
        let separator = "MACLEAN-OUTPUT-SEPARATOR-\(UUID().uuidString)"
        let list = "{" + invocations.map { arguments in
            "{" + ([helper] + arguments).map(literal).joined(separator: ", ") + "}"
        }.joined(separator: ", ") + "}"
        let source = """
            set invocations to \(list)
            set sep to \(literal(separator))
            set cmd to ""
            set savedDelimiters to AppleScript's text item delimiters
            repeat with i from 1 to count of invocations
              if i > 1 then set cmd to cmd & \(literal("; printf '%s\\n' ")) & quoted form of sep & \(literal("; "))
              set parts to {}
              repeat with a in item i of invocations
                set end of parts to quoted form of (contents of a)
              end repeat
              set AppleScript's text item delimiters to " "
              set cmd to cmd & (parts as text)
              set AppleScript's text item delimiters to savedDelimiters
            end repeat
            do shell script cmd with administrator privileges with prompt \(literal(prompt)) without altering line endings
            """
        return (source, separator)
    }

    /// An AppleScript string literal holding exactly `text`.
    private static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Splits the combined output at each separator line (the separator and
    /// its newline). Each invocation's own output keeps its trailing newline.
    static func split(_ output: String, separator: String) -> [String] {
        output.components(separatedBy: separator + "\n")
    }

    /// Runs `source` on the calling thread (always `queue`).
    private static func execute(_ source: String) -> Result<String, AdminRunnerError> {
        guard let script = NSAppleScript(source: source) else {
            return .failure(.failed("The administrator script couldn't be built."))
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -128 { return .failure(.cancelled) }
            let message = (error[NSAppleScript.errorMessage] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.failed(message.isEmpty ? "The administrator helper failed." : message))
        }
        return .success(result.stringValue ?? "")
    }
}
