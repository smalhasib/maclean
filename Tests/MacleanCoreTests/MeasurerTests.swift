import Foundation
import Testing
@testable import MacleanCore

private func setTime(_ path: String, daysAgo: Double) {
    let t = timeval(tv_sec: Int(Date().timeIntervalSince1970 - daysAgo * 86400), tv_usec: 0)
    var times = [t, t]
    precondition(utimes(path, &times) == 0)
}

@Suite struct MeasurerTests {
    @Test func measuresSizeCountAndNewest() throws {
        let t = TempDir()
        defer { withExtendedLifetime(t) {} }
        t.file("d/a", bytes: 4096)
        t.file("d/b", bytes: 4096)
        setTime(t.url("d/a"), daysAgo: 1)
        setTime(t.url("d/b"), daysAgo: 10)
        setTime(t.url("d"), daysAgo: 20)
        let m = try Measurer.measure(t.url("d"), context: MeasureContext())
        #expect(m.size >= 8192)
        #expect(m.fileCount == 2)
        #expect(m.isDirectory)
        #expect(!m.restricted)
        // ctime of the files is "now" from the utimes call itself, so only check the lower bound
        // is not older than the 1-day file.
        #expect(m.newest.timeIntervalSinceNow > -86400 - 2)
    }

    @Test func newestIsMaxOfMtimeAndCtime() throws {
        let t = TempDir()
        defer { withExtendedLifetime(t) {} }
        t.file("a", bytes: 10)
        setTime(t.url("a"), daysAgo: 10)  // mtime old, ctime now
        let m = try Measurer.measure(t.url("a"), context: MeasureContext())
        #expect(abs(m.newest.timeIntervalSinceNow) < 5)
    }

    @Test func directoryMtimeCounts() throws {
        let t = TempDir()
        defer { withExtendedLifetime(t) {} }
        t.file("d/old", bytes: 10)
        t.dir("d/sub")
        setTime(t.url("d/old"), daysAgo: 10)
        let m = try Measurer.measure(t.url("d"), context: MeasureContext())
        #expect(abs(m.newest.timeIntervalSinceNow) < 5)
    }

    @Test func symlinkIsNotFollowed() throws {
        let t = TempDir()
        defer { withExtendedLifetime(t) {} }
        t.file("big", bytes: 1 << 20)
        t.symlink("link", to: t.url("big"))
        let m = try Measurer.measure(t.url("link"), context: MeasureContext())
        #expect(m.fileCount == 1)
        #expect(m.size < 4096)
        #expect(!m.isDirectory)
    }

    @Test func hardLinkCountedOncePerContext() throws {
        let t = TempDir()
        defer { withExtendedLifetime(t) {} }
        t.file("a", bytes: 8192)
        t.hardlink("b", to: "a")
        let ctx = MeasureContext()
        let first = try Measurer.measure(t.url("a"), context: ctx)
        let second = try Measurer.measure(t.url("b"), context: ctx)
        #expect(first.size >= 8192)
        #expect(second.size == 0)
    }

    @Test func restrictedSubfolderFlagged() throws {
        let t = TempDir()
        defer { withExtendedLifetime(t) {} }
        t.file("d/ok", bytes: 10)
        t.dir("d/sub")
        t.chmod("d/sub", 0o000)
        let m = try Measurer.measure(t.url("d"), context: MeasureContext())
        #expect(m.restricted)
    }

    @Test func unreadableTopThrows() throws {
        let t = TempDir()
        defer { withExtendedLifetime(t) {} }
        t.dir("locked")
        t.chmod("locked", 0o000)
        #expect(throws: MeasureError.unreadable) {
            try Measurer.measure(t.url("locked"), context: MeasureContext())
        }
    }

    @Test func missingThrowsNotFound() {
        let t = TempDir()
        defer { withExtendedLifetime(t) {} }
        #expect(throws: MeasureError.notFound) {
            try Measurer.measure(t.url("nope"), context: MeasureContext())
        }
    }

    @Test func pastDeadlineThrowsTimedOut() {
        let t = TempDir()
        defer { withExtendedLifetime(t) {} }
        t.file("d/a", bytes: 10)
        #expect(throws: MeasureError.timedOut) {
            try Measurer.measure(t.url("d"), context: MeasureContext(), deadline: .now - .seconds(1))
        }
    }

    @Test func nestedModifiedReachesNewest() throws {
        let t = TempDir()
        defer { withExtendedLifetime(t) {} }
        t.file("d/sub/f", bytes: 10)
        setTime(t.url("d/sub/f"), daysAgo: 5)
        var st = stat()
        lstat(t.url("d"), &st)
        let dirTime = max(st.st_mtimespec.tv_sec, st.st_ctimespec.tv_sec)
        Thread.sleep(forTimeInterval: 2.1)
        let h = fopen(t.url("d/sub/f"), "w")
        fputs("x", h); fclose(h)
        lstat(t.url("d/sub/f"), &st)
        let fileTime = max(st.st_mtimespec.tv_sec, st.st_ctimespec.tv_sec)
        let m = try Measurer.measure(t.url("d"), context: MeasureContext())
        let newest = Int(m.newest.timeIntervalSince1970)
        #expect(abs(newest - fileTime) <= 1)
        #expect(newest > dirTime)
    }

    @Test func topLevelClonesCountedOncePerContext() throws {
        let t = TempDir()
        defer { withExtendedLifetime(t) {} }
        t.file("a", bytes: 1 << 20)
        guard clonefile(t.url("a"), t.url("b"), 0) == 0 else { return }  // not APFS
        let ctx = MeasureContext()
        let first = try Measurer.measure(t.url("a"), context: ctx)
        let second = try Measurer.measure(t.url("b"), context: ctx)
        #expect(first.size >= 1 << 20)
        #expect(second.size == 0)
    }
}
