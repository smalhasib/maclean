import Foundation
import MacleanCore

// maclean-scan <path> [--out <file>] [--top <n>]
// Exit codes: 0 ok, 1 root unreadable, 2 usage error. Progress -> stderr, summary -> stdout.

func usage() -> Never {
    fputs("usage: maclean-scan <path> [--out <file>] [--top <n>]\n", stderr)
    exit(2)
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

var path: String?
var outPath: String?
var top = 10
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--out":
        guard let value = args.next() else { usage() }
        outPath = value
    case "--top":
        guard let value = args.next(), let n = Int(value), n >= 0 else { usage() }
        top = n
    case _ where arg.hasPrefix("-") && arg != "-":
        usage()
    default:
        guard path == nil else { usage() }
        path = arg
    }
}
guard let path else { usage() }

let started = Date()
let tree: FileTree
do {
    tree = try await Scanner.scan(path: path) { p in
        let gb = Double(p.bytes) / 1_000_000_000
        fputs(String(format: "\r\u{1B}[K%.1f GB scanned, %lld items", gb, p.items), stderr)
    }
} catch {
    fputs("\nmaclean-scan: cannot scan \(path): \(error)\n", stderr)
    exit(1)
}
fputs("\r\u{1B}[K", stderr)
let elapsed = Date().timeIntervalSince(started)

var restricted = 0
for i in 0..<tree.count where tree.flags(of: NodeID(index: Int32(i))).contains(.restricted) {
    restricted += 1
}

let root = tree.root
print("Path:        \(tree.rootPath)")
print("Total size:  \(formatBytes(tree.size(of: root)))")
print("Files:       \(tree.fileCount(of: root))")
print("Restricted:  \(restricted)")
print(String(format: "Elapsed:     %.1f s", elapsed))
if top > 0 {
    print("Top \(top):")
    for child in tree.children(of: root).prefix(top) {
        print("  \(formatBytes(tree.size(of: child)).padding(toLength: 10, withPad: " ", startingAt: 0)) \(tree.name(of: child))")
    }
}

if let outPath {
    do {
        try TreeArchive.write(tree, to: URL(fileURLWithPath: outPath))
        print("Archive:     \(outPath)")
    } catch {
        fputs("maclean-scan: cannot write \(outPath): \(error)\n", stderr)
        exit(1)
    }
}
