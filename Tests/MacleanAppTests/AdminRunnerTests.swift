import Foundation
import Testing
@testable import Maclean

// Pure tests of the script builder and the output splitting: NSAppleScript is
// never executed here, so no administrator dialog can appear.

/// Splits AppleScript source into its string literals (decoded) and the code
/// outside them, following AppleScript's `\\` and `\"` escapes.
private func lex(_ source: String) -> (literals: [String], code: String) {
    var literals: [String] = [], code = "", current = ""
    var inLiteral = false, escaped = false
    for ch in source {
        if inLiteral {
            if escaped {
                // Only `\\` and `\"` matter here; others keep their backslash.
                current.append(ch == "\\" || ch == "\"" ? String(ch) : "\\" + String(ch))
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                literals.append(current)
                current = ""
                inLiteral = false
                code.append("\"\"")
            } else {
                current.append(ch)
            }
        } else if ch == "\"" {
            inLiteral = true
        } else {
            code.append(ch)
        }
    }
    #expect(!inLiteral, "unterminated string literal")
    return (literals, code)
}

@Test func scriptQuotesEveryArgument() {
    let args = ["--delete", "a b", "x\"y\\z", "$(rm -rf ~)", "it's; `id`"]
    let (source, separator) = AdminRunner.script(helper: "/Apps/Mac lean.app/Contents/MacOS/maclean-scan",
                                                 invocations: [args], prompt: "Why")
    let (literals, code) = lex(source)
    // Every argument, and the helper path, survives as exactly one literal.
    for arg in args + ["/Apps/Mac lean.app/Contents/MacOS/maclean-scan"] {
        #expect(literals.contains(arg), "missing literal \(arg)")
    }
    // No argument text leaks into code outside the literals.
    for fragment in ["rm -rf", "a b", "y\\z", "`id`", "Mac lean"] {
        #expect(!code.contains(fragment), "\(fragment) outside a literal")
    }
    // The arguments sit in a list literal and each element goes through
    // `quoted form of` before reaching the shell.
    #expect(code.contains("{{\"\", \"\", \"\", \"\", \"\", \"\"}}"))
    #expect(code.contains("quoted form of (contents of a)"))
    #expect(code.contains("do shell script cmd with administrator privileges with prompt \"\""))
    #expect(!separator.isEmpty)
}

@Test func scriptJoinsInvocationsWithSeparator() {
    let (source, separator) = AdminRunner.script(helper: "/h", invocations: [["--one"], ["--two"]], prompt: "Why")
    let (literals, code) = lex(source)
    #expect(literals.filter { $0 == separator }.count == 1)
    // Every invocation, the last included, is followed by its status line.
    #expect(literals.contains("; printf '%s %d\\n' "))
    #expect(literals.contains(" $?"))
    #expect(literals.contains("; "))
    #expect(code.contains("(parts as text) & \"\" & quoted form of sep & \"\""))
    #expect(literals.contains("--one") && literals.contains("--two"))
    // A fresh separator per call.
    let (_, other) = AdminRunner.script(helper: "/h", invocations: [["--one"], ["--two"]], prompt: "Why")
    #expect(other != separator)
}

@Test func splitOutputsBySeparator() {
    #expect(AdminRunner.split("out1\n<sep> 0\nout2<sep> 0\n", separator: "<sep>")
            == [AdminOutput(stdout: "out1\n", status: 0), AdminOutput(stdout: "out2", status: 0)])
    #expect(AdminRunner.split("<sep> 0\n", separator: "<sep>") == [AdminOutput(stdout: "", status: 0)])
    #expect(AdminRunner.split("", separator: "<sep>") == [])
}

@Test func splitCarriesPerInvocationStatus() {
    // A mixed batch: the first invocation succeeds, the second fails.
    #expect(AdminRunner.split("ok\n<sep> 0\nboom\n<sep> 1\n", separator: "<sep>")
            == [AdminOutput(stdout: "ok\n", status: 0), AdminOutput(stdout: "boom\n", status: 1)])
}

@Test func splitFailsClosedOnMalformedStatus() {
    for output in [
        "out",                       // no status line at all
        "out\n<sep>\n",              // separator without a status
        "out\n<sep> x\n",            // non-numeric status
        "out\n<sep> -1\n",           // sign
        "out\n<sep> 0",               // unterminated status line
        "out\n<sep> 99999999999\n",  // out of range
        "out\n<sep> 0\ntrailing",     // text after the last status line
        "a<sep> 0 extra\n",           // junk after the status
    ] {
        #expect(AdminRunner.split(output, separator: "<sep>") == nil, "accepted \(output.debugDescription)")
    }
}

@Test func promptIsEscaped() {
    let prompt = "Maclean \"needs\" C:\\path; do shell script \"rm\""
    let (source, _) = AdminRunner.script(helper: "/h", invocations: [["--x"]], prompt: prompt)
    let (literals, code) = lex(source)
    #expect(literals.contains(prompt))
    #expect(!code.contains("C:"))
    #expect(!code.contains("needs"))
}

private struct StubRunner: AdminRunning {
    let outputs: [AdminOutput]
    func run(_ invocations: [[String]], prompt: String) async throws -> [AdminOutput] { outputs }
}

@Test func singleRunThrowsOnNonZeroExit() async throws {
    await #expect(throws: AdminRunnerError.failed("helper exited 3")) {
        try await StubRunner(outputs: [AdminOutput(stdout: "partial", status: 3)]).run(["--x"], prompt: "p")
    }
    #expect(try await StubRunner(outputs: [AdminOutput(stdout: "fine", status: 0)]).run(["--x"], prompt: "p") == "fine")
}
