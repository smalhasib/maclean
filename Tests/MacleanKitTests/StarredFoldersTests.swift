import Foundation
import Testing
@testable import MacleanKit

@MainActor @Suite struct StarredFoldersTests {
    private func fixture() throws -> (UserDefaults, String, URL) {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("starred-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Bookmarks resolve to the canonical (/private/var) form of the path.
        let real = try #require(realpath(dir.path, nil))
        defer { free(real) }
        return (defaults, suite, URL(fileURLWithPath: String(cString: real)))
    }

    @Test func starRoundTrip() throws {
        let (d, suite, dir) = try fixture()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        StarredFolders(defaults: d).star(a)
        #expect(StarredFolders(defaults: d).paths == [a.path])
        let s = StarredFolders(defaults: d)
        s.unstar(a.path)
        #expect(StarredFolders(defaults: d).paths.isEmpty)
    }

    @Test func movedStarredFolderFollows() throws {
        let (d, suite, dir) = try fixture()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        let s = StarredFolders(defaults: d)
        s.star(a)
        try FileManager.default.moveItem(at: a, to: b)
        #expect(s.resolve() == [b.path])
        #expect(StarredFolders(defaults: d).paths == [b.path])
    }

    @Test func deletedStarredFolderDropped() throws {
        let (d, suite, dir) = try fixture()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        let s = StarredFolders(defaults: d)
        s.star(a)
        try FileManager.default.removeItem(at: a)
        #expect(s.resolve() == [])
        #expect(s.paths == [])
    }
}
