import Foundation
import Testing
import MacleanCore
@testable import Maclean

// The preview pane shows the file under the pointer, else the selected one, and keeps
// showing it when the pointer leaves (so a video can be played).

@Test @MainActor func hoveredFileIsPreviewedThenSelectedWhenNotHovering() async throws {
    let s = Scratch()
    s.file("a.txt", bytes: 4096); s.file("b.txt", bytes: 8192)
    let session = await scannedSession(s)
    let m = model(session)
    let a = try #require(m.tree.node(atPath: s.path + "/a.txt"))
    let b = try #require(m.tree.node(atPath: s.path + "/b.txt"))
    #expect(m.previewNode == nil)

    m.selected = a
    #expect(m.previewNode == a)
    m.hover(b, from: .list)
    #expect(m.previewNode == b)         // under the pointer comes first
}

@Test @MainActor func previewStaysWhenThePointerLeaves() async throws {
    let s = Scratch()
    s.file("a.txt", bytes: 4096)
    let session = await scannedSession(s)
    let m = model(session)
    let a = try #require(m.tree.node(atPath: s.path + "/a.txt"))
    m.hover(a, from: .list)
    #expect(m.previewNode == a)
    m.hover(nil, from: .list)
    #expect(m.previewNode == a)         // so the pane can be used (play, scroll)
}

@Test @MainActor func foldersAndOtherKindsAreNotPreviewed() async throws {
    let s = Scratch()
    s.file("dir/x.txt", bytes: 4096); s.file("a.txt", bytes: 4096)
    let session = await scannedSession(s)
    let m = model(session)
    let dir = try #require(m.tree.node(atPath: s.path + "/dir"))
    let a = try #require(m.tree.node(atPath: s.path + "/a.txt"))
    m.selected = a
    m.hover(dir, from: .list)
    #expect(m.previewNode == a)         // a folder under the pointer leaves the last file showing
    m.selected = dir
    #expect(m.previewNode == a)
}

@Test @MainActor func collectedFileLeavesThePreview() async throws {
    let s = Scratch()
    s.file("a.txt", bytes: 4096); s.file("b.txt", bytes: 4096)
    let session = await scannedSession(s)
    let m = model(session)
    let a = try #require(m.tree.node(atPath: s.path + "/a.txt"))
    m.selected = a
    #expect(m.previewNode == a)
    session.collect([a])
    m.viewDidChange()
    #expect(m.previewNode == nil)       // it's hidden from the list now
}

@Test func previewInfoDescribesARegularFile() throws {
    let s = Scratch()
    s.file("note.txt", bytes: 5000)
    let info = try #require(PreviewInfo.read(path: s.path + "/note.txt"))
    #expect(info.name == "note.txt")
    #expect(info.kind.localizedCaseInsensitiveContains("text"))
    #expect(info.size == 5000)
    #expect(info.modified != nil)
}

@Test func previewInfoRefusesWhatIsNotARegularFile() throws {
    let s = Scratch()
    s.file("real.txt", bytes: 4096)
    #expect(PreviewInfo.read(path: s.path + "/missing.txt") == nil)
    #expect(PreviewInfo.read(path: s.path) == nil)   // a folder
    symlink(s.path + "/real.txt", s.path + "/link.txt")
    #expect(PreviewInfo.read(path: s.path + "/link.txt") == nil)   // not followed
    mkfifo(s.path + "/pipe", 0o600)
    #expect(PreviewInfo.read(path: s.path + "/pipe") == nil)       // opening it could block
}
