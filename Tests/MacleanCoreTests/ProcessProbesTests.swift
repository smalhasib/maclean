import Foundation
import Testing
@testable import MacleanCore

@Suite struct ProcessProbesTests {
    @Test func pathsOpenSeesOwnOpenFile() throws {
        let t = TempDir()
        defer { withExtendedLifetime(t) {} }
        t.file("open/held.txt", bytes: 10)
        t.file("closed/idle.txt", bytes: 10)
        let handle = try #require(FileHandle(forReadingAtPath: t.url("open/held.txt")))
        defer { try? handle.close() }
        #expect(ProcessProbes.pathsOpen(under: t.url("open")) == true)
        #expect(ProcessProbes.pathsOpen(under: t.url("open/held.txt")) == true)
        #expect(ProcessProbes.pathsOpen(under: t.url("closed")) == false)
        // A sibling sharing the name prefix is not "under".
        #expect(ProcessProbes.pathsOpen(under: t.url("ope")) == false)
    }

    @Test func workingDirectoriesIncludeSelf() throws {
        let dirs = try #require(ProcessProbes.workingDirectories())
        let cwd = try #require(ScanBoundary.canonicalPath(FileManager.default.currentDirectoryPath))
        #expect(dirs.contains(cwd))
    }

    @Test func processNamesIncludeSelf() throws {
        let names = try #require(ProcessProbes.processNames())
        var buf = [CChar](repeating: 0, count: 1024)
        #expect(proc_name(getpid(), &buf, UInt32(buf.count)) > 0)
        let own = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #expect(names.contains(own))
    }
}
