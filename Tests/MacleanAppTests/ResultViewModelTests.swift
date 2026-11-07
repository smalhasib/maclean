import Foundation
import Testing
import MacleanCore
import MacleanKit
@testable import Maclean

/// Scratch directory removed on deinit; only ever touches its own files.
final class Scratch {
    let path: String
    init() {
        let base = ScanBoundary.canonicalPath(FileManager.default.temporaryDirectory.path)!
        path = base + "/maclean-app-tests-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(atPath: path) }
    func file(_ rel: String, bytes: Int) {
        let full = path + "/" + rel
        try! FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: full, contents: Data(count: bytes))
    }
    func remove(_ rel: String) { try! FileManager.default.removeItem(atPath: path + "/" + rel) }
}

@MainActor func scannedSession(_ s: Scratch) async -> ScanSession {
    let session = ScanSession(rootPath: s.path)
    session.start()
    while session.isScanning { try? await Task.sleep(for: .milliseconds(10)) }
    return session
}

@MainActor func model(_ session: ScanSession) -> ResultViewModel {
    ResultViewModel(session: session, ownsSessionHistory: false,
                    defaults: UserDefaults(suiteName: "maclean-tests-\(UUID().uuidString)")!)
}

@Test @MainActor func vanishedCurrentFolderFallsBackToAncestor() async throws {
    let s = Scratch()
    s.file("a/b/x.bin", bytes: 4096)
    s.file("a/keep.bin", bytes: 4096)
    let session = await scannedSession(s)
    let old = model(session)
    let aPath = s.path + "/a", bPath = aPath + "/b"
    old.visit(path: bPath)
    #expect(old.history.current == bPath)

    s.remove("a/b")
    session.rescan()
    while session.isScanning { try await Task.sleep(for: .milliseconds(10)) }
    let tree = try #require(session.tree)

    let m = ResultViewModel(remapping: old, to: tree, ownsSessionHistory: false)
    #expect(m.currentNode == tree.node(atPath: aPath))
    #expect(m.history.current == aPath)
}

@Test @MainActor func fallbackWhenHistoryChangesToMissingPath() async throws {
    let s = Scratch()
    s.file("a/b/x.bin", bytes: 4096)
    let session = await scannedSession(s)
    let m = model(session)
    let aPath = s.path + "/a"
    m.visit(path: aPath)
    m.visit(path: aPath + "/gone/deeper")
    let tree = m.tree
    #expect(m.currentNode == tree.node(atPath: aPath))
    #expect(m.history.current == aPath)
}

@Test @MainActor func backSkipsMissingEntries() async throws {
    let s = Scratch()
    s.file("a/b/x.bin", bytes: 4096)
    s.file("c/y.bin", bytes: 4096)
    let session = await scannedSession(s)
    let old = model(session)
    old.visit(path: s.path + "/a/b")
    old.visit(path: s.path + "/c")
    s.remove("a")
    session.rescan()
    while session.isScanning { try await Task.sleep(for: .milliseconds(10)) }
    let m = ResultViewModel(remapping: old, to: try #require(session.tree), ownsSessionHistory: false)
    #expect(m.history.current == s.path + "/c")
    m.back()
    #expect(m.history.current == s.path)
    #expect(!m.history.canGoBack)
}
