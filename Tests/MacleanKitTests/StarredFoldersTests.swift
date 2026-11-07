import Foundation
import Testing
@testable import MacleanKit

@MainActor @Suite struct StarredFoldersTests {
    private final class Fixture {
        let defaults: UserDefaults
        let suite = UUID().uuidString
        let dir: URL
        var mounts = ["/"]

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("starred-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            // Canonical (/private/var) form, as starred paths are stored.
            let real = try #require(realpath(base.path, nil))
            defer { free(real) }
            dir = URL(fileURLWithPath: String(cString: real))
        }

        @MainActor func make() -> StarredFolders {
            StarredFolders(defaults: defaults, mountPoints: { [unowned self] in self.mounts })
        }

        func mkdir(_ name: String) throws -> URL {
            let u = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            return u
        }

        deinit {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @Test func starRoundTrip() throws {
        let f = try Fixture()
        let a = try f.mkdir("a")
        f.make().star(a)
        #expect(f.make().paths == [a.path])
        f.make().unstar(a.path)
        #expect(f.make().paths.isEmpty)
    }

    @Test func movedStarredFolderFollows() throws {
        let f = try Fixture()
        let a = try f.mkdir("a"), b = f.dir.appendingPathComponent("b")
        let s = f.make()
        s.star(a)
        try FileManager.default.moveItem(at: a, to: b)
        #expect(s.resolve() == [b.path])
        #expect(f.make().paths == [b.path])
    }

    @Test func backgroundResolveFollowsMovesAndDropsDeleted() async throws {
        let f = try Fixture()
        let a = try f.mkdir("a"), b = f.dir.appendingPathComponent("b"), c = try f.mkdir("c")
        let s = f.make()
        s.star(a)
        s.star(c)
        try FileManager.default.moveItem(at: a, to: b)
        try FileManager.default.removeItem(at: c)
        #expect(await s.resolveInBackground() == [b.path])
        #expect(f.make().paths == [b.path])
    }

    @Test func deletedStarredFolderDropped() throws {
        let f = try Fixture()
        let a = try f.mkdir("a")
        let s = f.make()
        s.star(a)
        try FileManager.default.removeItem(at: a)
        #expect(s.resolve() == [])
        #expect(s.paths == [])
    }

    @Test func unmountedVolumeStarKeptUntilItReturns() throws {
        let f = try Fixture()
        let a = try f.mkdir("a")
        f.mounts = ["/", f.dir.path]        // dir plays a mounted volume
        let s = f.make()
        s.star(a)
        f.mounts = ["/"]                    // "eject"
        try FileManager.default.removeItem(at: a)
        #expect(s.resolve() == [a.path])
        f.mounts = ["/", f.dir.path]        // back, but the folder is really gone
        #expect(s.resolve() == [])
    }

    @Test func folderMovedToTrashDropped() throws {
        let f = try Fixture()
        let a = try f.mkdir("a")
        let trash = try f.mkdir(".Trash")
        let s = f.make()
        s.star(a)
        try FileManager.default.moveItem(at: a, to: trash.appendingPathComponent("a"))
        #expect(s.resolve() == [])
    }

    @Test func symlinkAndTargetYieldOneEntry() throws {
        let f = try Fixture()
        let a = try f.mkdir("a")
        let link = f.dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
        let s = f.make()
        s.star(a)
        s.star(link)
        #expect(s.paths == [a.path])
        #expect(s.resolve() == [a.path])
    }
}
