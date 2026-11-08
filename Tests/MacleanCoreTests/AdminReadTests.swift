import Darwin
import Foundation
import Testing
@testable import MacleanCore

private func scanner(_ path: String, _ boundary: ScanBoundary) async throws -> FileTree {
    try await Scanner.scan(path: path, boundary: boundary)
}

private func removeDir(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

private func request(root: String, paths: [String], outDir: URL, uid: uid_t = getuid()) -> AdminRead.Request {
    AdminRead.Request(root: root, paths: paths, outDir: outDir.path, uid: uid)
}

private func entries(_ dir: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
}

@Test func readArgumentsRoundTrip() throws {
    let paths = ["/Users/me/a b", "/Users/me/new\nline", "/Users/me/--uid", "/x/$(rm -rf ~) é"]
    let (file, hash) = try AdminRead.writePathsFile(paths)
    defer { AdminMeasure.removePathsFile(file) }
    let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attrs[.posixPermissions] as? Int) == 0o600)

    let args = AdminRead.arguments(root: "/Users/me", pathsFile: file.path, sha256: hash, outDir: "/tmp/o", uid: 501)
    #expect(args == ["read-restricted", "--root", "/Users/me", "--paths-file", file.path, "--paths-sha256", hash,
                     "--out-dir", "/tmp/o", "--uid", "501"])
    let parsed = try AdminRead.parse(args)
    #expect(parsed == AdminRead.Request(root: "/Users/me", paths: paths, outDir: "/tmp/o", uid: 501))

    #expect(throws: (any Error).self) { try AdminRead.parse(Array(args.dropLast())) }
    #expect(throws: (any Error).self) { try AdminRead.parse(args + ["extra"]) }
    var wrongMode = args
    wrongMode[0] = "smart-measure"
    #expect(throws: (any Error).self) { try AdminRead.parse(wrongMode) }
    for bad in ["-1", "x", "", "4294967296", "0"] {
        var badUID = args
        badUID[10] = bad
        #expect(throws: (any Error).self) { try AdminRead.parse(badUID) }
    }
    var swapped = args
    swapped.swapAt(1, 7)
    #expect(throws: (any Error).self) { try AdminRead.parse(swapped) }
}

@Test func readRefusesTamperedPathsFile() throws {
    let (file, hash) = try AdminRead.writePathsFile(["/Users/me/a"])
    defer { AdminMeasure.removePathsFile(file) }
    let good = AdminRead.arguments(root: "/Users/me", pathsFile: file.path, sha256: hash, outDir: "/tmp/o", uid: 501)
    #expect(try AdminRead.parse(good).paths == ["/Users/me/a"])

    try Data(#"["/etc"]"#.utf8).write(to: file)
    #expect(throws: (any Error).self) { try AdminRead.parse(good) }

    let (fresh, freshHash) = try AdminRead.writePathsFile(["/Users/me/a"])
    defer { AdminMeasure.removePathsFile(fresh) }
    let link = file.deletingLastPathComponent().appending(path: "link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fresh)
    let viaLink = AdminRead.arguments(root: "/Users/me", pathsFile: link.path, sha256: freshHash,
                                      outDir: "/tmp/o", uid: 501)
    #expect(throws: (any Error).self) { try AdminRead.parse(viaLink) }
}

@Test func readMakeOutDirIsPrivate() throws {
    let dir = try AdminRead.makeOutDir()
    defer { removeDir(dir) }
    var st = stat()
    #expect(lstat(dir.path, &st) == 0)
    #expect((st.st_mode & S_IFMT) == S_IFDIR)
    #expect((st.st_mode & 0o7777) == 0o700)
    #expect(st.st_uid == getuid())
}

@Test func readRefusesOutDirSymlinkOrWrongOwnerOrMode() async throws {
    let t = TempDir()
    defer { withExtendedLifetime(t) {} }
    t.file("r/a/f", bytes: 5000)
    t.file("r/b/g", bytes: 5000)
    let paths = [t.url("r/a"), t.url("r/b")]
    let out = try AdminRead.makeOutDir()
    defer { removeDir(out) }

    func expectRefused(_ req: AdminRead.Request) async {
        let lines = await AdminRead.perform(req, scan: scanner)
        #expect(lines.map(\.path) == paths)
        #expect(lines.allSatisfy { $0.file == nil && $0.error != nil })
        #expect(entries(out).isEmpty)
    }

    // A symlink to a good directory.
    let link = URL(fileURLWithPath: t.url("out-link"))
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: out)
    await expectRefused(request(root: t.url("r"), paths: paths, outDir: link))
    // Wrong owner.
    await expectRefused(request(root: t.url("r"), paths: paths, outDir: out, uid: getuid() + 1))
    // Wrong mode.
    #expect(chmod(out.path, 0o755) == 0)
    await expectRefused(request(root: t.url("r"), paths: paths, outDir: out))
    #expect(chmod(out.path, 0o700) == 0)
    // Not a directory, or missing.
    t.file("plain")
    await expectRefused(request(root: t.url("r"), paths: paths, outDir: URL(fileURLWithPath: t.url("plain"))))
    await expectRefused(request(root: t.url("r"), paths: paths, outDir: URL(fileURLWithPath: t.url("nope"))))
}

@Test func readRefusesPathOutsideRoot() async throws {
    let t = TempDir()
    defer { withExtendedLifetime(t) {} }
    t.file("r/a/f", bytes: 5000)
    t.file("other/secret", bytes: 5000)
    t.symlink("r/link", to: t.url("other"))
    let out = try AdminRead.makeOutDir()
    defer { removeDir(out) }

    let paths = [t.url("other"), t.url("r/../other"), t.url("r/link"), t.url("r"), "/", t.url("r/a/../a"),
                 t.url("r/missing"), t.url("r/a")]
    let lines = await AdminRead.perform(request(root: t.url("r"), paths: paths, outDir: out), scan: scanner)
    #expect(lines.map(\.path) == paths)
    for line in lines.prefix(6) {
        #expect(line.error == AdminRead.outsideTheScan && line.file == nil, "\(line.path)")
    }
    #expect(lines[6].error != nil && lines[6].file == nil)
    #expect(lines[7].error == nil && lines[7].file != nil)
    #expect(entries(out) == ["7.mtree"])
}

@Test func readWritesArchivePerPath() async throws {
    let t = TempDir()
    defer { withExtendedLifetime(t) {} }
    t.file("r/a/f", bytes: 5000)
    t.file("r/a/deep/g", bytes: 9000)
    t.file("r/b/h", bytes: 20000)
    let out = try AdminRead.makeOutDir()
    defer { removeDir(out) }
    let paths = [t.url("r/a"), t.url("r/b")]

    let lines = await AdminRead.perform(request(root: t.url("r"), paths: paths, outDir: out), scan: scanner)
    #expect(lines.map(\.error) == [nil, nil])
    #expect(lines.map(\.file) == [out.appending(path: "0.mtree").path, out.appending(path: "1.mtree").path])
    #expect(Set(entries(out)) == ["0.mtree", "1.mtree"])

    for (line, path) in zip(lines, paths) {
        let file = try #require(line.file)
        var st = stat()
        #expect(lstat(file, &st) == 0)
        #expect((st.st_mode & S_IFMT) == S_IFREG)
        #expect((st.st_mode & 0o7777) == 0o600)
        #expect(st.st_uid == getuid())
        let tree = try TreeArchive.read(from: URL(fileURLWithPath: file))
        let expected = try await Scanner.scan(path: path)
        #expect(tree.rootPath == path)
        #expect(tree.size(of: tree.root) == expected.size(of: expected.root))
        #expect(tree.size(of: tree.root) > 0)
        #expect(tree.fileCount(of: tree.root) == expected.fileCount(of: expected.root))
    }

    // Lines round-trip as JSON lines.
    let text = lines.map(AdminRead.encode).joined(separator: "\n")
    let decoded = AdminRead.decode(text)
    #expect(decoded[paths[0]] == lines[0] && decoded[paths[1]] == lines[1])
}

@Test func readReportsScanFailure() async throws {
    let t = TempDir()
    defer { withExtendedLifetime(t) {} }
    t.dir("r/a")
    let out = try AdminRead.makeOutDir()
    defer { removeDir(out) }
    struct Boom: Error {}
    let lines = await AdminRead.perform(request(root: t.url("r"), paths: [t.url("r/a")], outDir: out)) { _, _ in
        throw Boom()
    }
    #expect(lines.count == 1 && lines[0].error != nil && lines[0].file == nil)
    #expect(entries(out).isEmpty)
}
