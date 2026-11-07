import Foundation
import MacleanCore

// maclean-scan <path> [--out <file>] [--top <n>]
// Exit codes: 0 ok, 1 root unreadable, 2 usage error, 3 output write failed. Progress -> stderr, summary -> stdout.

func usage() -> Never {
    fputs("""
        usage: maclean-scan <path> [--out <file>] [--top <n>]
        exit codes: 0 ok, 1 root unreadable, 2 usage error, 3 output write failed

        """, stderr)
    exit(2)
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// Replaces control characters (C0, DEL, C1) with visible \u{XX} escapes so
/// file names cannot inject terminal escape sequences.
func sanitized(_ text: String) -> String {
    var out = ""
    for scalar in text.unicodeScalars {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F:
            out += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
        default:
            out.unicodeScalars.append(scalar)
        }
    }
    return out
}

/// Short, path-free reason for a failed archive write.
func writeFailureReason(_ error: Error) -> String {
    let ns = error as NSError
    if ns.domain == NSPOSIXErrorDomain { return String(cString: strerror(Int32(ns.code))) }
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
        return String(cString: strerror(Int32(underlying.code)))
    }
    return "write failed"
}

var path: String?
var outPath: String?
var top = 10
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--out":
        guard let value = args.next(), !value.hasPrefix("--") else { usage() }
        outPath = value
    case "--top":
        guard let value = args.next(), !value.hasPrefix("--"), let n = Int(value), n >= 0 else { usage() }
        top = n
    case _ where arg.hasPrefix("-") && arg != "-":
        usage()
    default:
        guard path == nil else { usage() }
        path = arg
    }
}
guard let path else { usage() }

let showProgress = isatty(2) != 0
let started = Date()
let tree: FileTree
do {
    tree = try await Scanner.scan(path: path) { p in
        guard showProgress else { return }
        let gb = Double(p.bytes) / 1_000_000_000
        fputs(String(format: "\r\u{1B}[K%.1f GB scanned, %lld items", gb, p.items), stderr)
    }
} catch {
    if showProgress { fputs("\r\u{1B}[K", stderr) }
    fputs("maclean-scan: cannot scan \(sanitized(path)): \(sanitized(String(describing: error)))\n", stderr)
    exit(1)
}
if showProgress { fputs("\r\u{1B}[K", stderr) }
let elapsed = Date().timeIntervalSince(started)

var restricted = 0
for i in 0..<tree.count where tree.flags(of: NodeID(index: Int32(i))).contains(.restricted) {
    restricted += 1
}

let root = tree.root
print("Path:        \(sanitized(tree.rootPath))")
print("Total size:  \(formatBytes(tree.size(of: root)))")
print("Files:       \(tree.fileCount(of: root))")
print("Restricted:  \(restricted)")
print(String(format: "Elapsed:     %.1f s", elapsed))
if top > 0 {
    print("Top \(top):")
    for child in tree.children(of: root).prefix(top) {
        print("  \(formatBytes(tree.size(of: child)).padding(toLength: 10, withPad: " ", startingAt: 0)) \(sanitized(tree.name(of: child)))")
    }
}

if let outPath {
    do {
        try TreeArchive.write(tree, to: URL(fileURLWithPath: outPath))
        print("Archive:     \(sanitized(outPath))")
    } catch {
        fputs("maclean-scan: cannot write \(sanitized(outPath)): \(writeFailureReason(error))\n", stderr)
        exit(3)
    }
}
