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
    #expect(literals.contains("; printf '%s\\n' "))
    #expect(literals.contains("; "))
    #expect(code.contains("quoted form of sep"))
    #expect(literals.contains("--one") && literals.contains("--two"))
    // A fresh separator per call.
    let (_, other) = AdminRunner.script(helper: "/h", invocations: [["--one"], ["--two"]], prompt: "Why")
    #expect(other != separator)
}

@Test func splitOutputsBySeparator() {
    #expect(AdminRunner.split("out1\n<sep>\nout2", separator: "<sep>") == ["out1\n", "out2"])
    #expect(AdminRunner.split("only", separator: "<sep>") == ["only"])
    #expect(AdminRunner.split("a\n<sep>\n\n<sep>\nc\n", separator: "<sep>") == ["a\n", "\n", "c\n"])
}

@Test func promptIsEscaped() {
    let prompt = "Maclean \"needs\" C:\\path; do shell script \"rm\""
    let (source, _) = AdminRunner.script(helper: "/h", invocations: [["--x"]], prompt: prompt)
    let (literals, code) = lex(source)
    #expect(literals.contains(prompt))
    #expect(!code.contains("C:"))
    #expect(!code.contains("needs"))
}
