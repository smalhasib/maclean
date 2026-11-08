import Darwin
import Foundation
import Testing
@testable import Maclean

@Suite struct FullDiskAccessTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fda-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func missingFirstProbeFallsThroughToReadableOne() throws {
        // macOS 27 has no per-user com.apple.TCC folder: a missing probe must not decide.
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let readable = dir.appendingPathComponent("readable")
        try Data("x".utf8).write(to: readable)
        #expect(FullDiskAccess.isGranted(probes: [dir.appendingPathComponent("missing").path, readable.path]))
    }

    @Test func readableDirectoryCounts() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(FullDiskAccess.isGranted(probes: [dir.path]))
    }

    @Test func refusedOrMissingProbesMeanNoAccess() throws {
        let dir = try scratch()
        defer {
            chmod(dir.appendingPathComponent("locked").path, 0o600)
            try? FileManager.default.removeItem(at: dir)
        }
        let locked = dir.appendingPathComponent("locked")
        try Data("x".utf8).write(to: locked)
        chmod(locked.path, 0o000)
        #expect(!FullDiskAccess.isGranted(probes: [locked.path, dir.appendingPathComponent("missing").path]))
        #expect(!FullDiskAccess.isGranted(probes: []))
    }

    @Test func defaultProbesAvoidPromptingFolders() {
        // Desktop, Documents and Downloads raise a consent dialog; the probe must never touch them.
        let probes = FullDiskAccess.defaultProbes(home: "/Users/me")
        #expect(probes.first == "/Library/Application Support/com.apple.TCC/TCC.db")
        for folder in ["Desktop", "Documents", "Downloads"] {
            #expect(!probes.contains { $0.hasPrefix("/Users/me/\(folder)") })
        }
    }
}
