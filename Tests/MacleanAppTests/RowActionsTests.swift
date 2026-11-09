import Foundation
import Testing
import MacleanCore
@testable import Maclean

// Preview and Delete on a list row: the hover buttons and the right-click menu.

@Test @MainActor func contextMenuOffersPreviewAndDelete() async throws {
    let s = Scratch()
    s.file("a.txt", bytes: 4096); s.file("d/x.txt", bytes: 4096)
    let session = await scannedSession(s)
    let m = model(session)
    let a = try #require(m.tree.node(atPath: s.path + "/a.txt"))
    let d = try #require(m.tree.node(atPath: s.path + "/d"))
    let actions = ResultActions(model: m, router: nil)

    let fileTitles = actions.contextItems(for: a).map(\.title)
    #expect(fileTitles.contains("Preview"))
    #expect(fileTitles.contains("Delete “a.txt”…"))
    #expect(actions.contextItems(for: d).map(\.title).contains("Delete “d”…"))
}

@Test @MainActor func hoverButtonsFollowTheItemKind() async throws {
    let s = Scratch()
    s.file("a.txt", bytes: 4096); s.file("d/x.txt", bytes: 4096)
    let session = await scannedSession(s)
    let m = model(session)
    let a = try #require(m.tree.node(atPath: s.path + "/a.txt"))
    let d = try #require(m.tree.node(atPath: s.path + "/d"))
    let actions = ResultActions(model: m, router: nil)
    #expect(actions.canPreviewFromRow(a))
    #expect(!actions.canPreviewFromRow(d))   // Quick Look has nothing to show for a folder
    #expect(actions.canCollectFromRow(a))   // the hover button collects; Delete stays in the menu
    #expect(actions.canCollectFromRow(d))
    #expect(actions.canDeleteFromRow(a))
    #expect(actions.canDeleteFromRow(d))
}
