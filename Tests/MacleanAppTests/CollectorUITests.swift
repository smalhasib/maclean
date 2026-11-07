import Foundation
import Testing
import MacleanCore
import MacleanKit
@testable import Maclean

@Test @MainActor func moveAllFromCurrentFolderCollectsVisibleChildren() async throws {
    let s = Scratch()
    s.file("a/x.bin", bytes: 64 * 1024)
    s.file("b/y.bin", bytes: 32 * 1024)
    s.file("c.bin", bytes: 16 * 1024)
    let session = await scannedSession(s)
    let m = model(session)
    m.collectAllInCurrentFolder()
    m.viewDidChange()
    let tree = try #require(session.tree)
    #expect(Set(m.view.collected) == Set(tree.children(of: tree.root)))
    #expect(m.view.size(of: tree.root) == 0)
    #expect(m.collectorRefusal == nil)
}

@Test @MainActor func finderDropInsideScanCollectsOutsideRefuses() async throws {
    let s = Scratch()
    s.file("a/x.bin", bytes: 8192)
    s.file("b/y.bin", bytes: 8192)
    let outside = Scratch()
    outside.file("z.bin", bytes: 4096)
    let session = await scannedSession(s)
    let m = model(session)
    let tree = try #require(session.tree)
    let x = try #require(tree.node(atPath: s.path + "/a/x.bin"))

    m.collectDropped(paths: [s.path + "/a/x.bin"])
    #expect(m.view.collected == [x])
    #expect(m.collectorRefusal == nil)

    m.collectDropped(paths: [outside.path + "/z.bin"])
    #expect(m.collectorRefusal?.text == "“z.bin” isn't in this scan.")
    #expect(m.view.collected == [x])

    // Already hidden (collected) is refused the same way.
    m.dismissCollectorRefusal()
    m.collectDropped(paths: [s.path + "/a/x.bin"])
    #expect(m.collectorRefusal?.text == "“x.bin” isn't in this scan.")
}

@Test @MainActor func finderDropResolvesNonCanonicalParent() async throws {
    let s = Scratch()
    s.file("a/x.bin", bytes: 8192)
    let session = await scannedSession(s)
    let m = model(session)
    let tree = try #require(session.tree)
    let x = try #require(tree.node(atPath: s.path + "/a/x.bin"))
    #expect(m.visibleNode(forDroppedPath: s.path + "/a/../a/x.bin") == x)
    #expect(m.visibleNode(forDroppedPath: "/nonexistent/x.bin") == nil)
}

@Test @MainActor func dragPayloadsAreScopedToSession() async throws {
    let s = Scratch()
    s.file("a/x.bin", bytes: 8192)
    s.file("b/y.bin", bytes: 4096)
    let session = await scannedSession(s)
    let other = await scannedSession(s)
    let m = model(session)
    let tree = try #require(session.tree)
    let a = try #require(tree.node(atPath: s.path + "/a"))

    let payload = m.dragPayload(for: a)
    #expect(NodeDragPayload(data: payload.data) == payload)
    #expect(m.canCollect(payload))
    #expect(!m.isCollected(payload))
    #expect(!model(other).canCollect(payload))

    m.collect([a])
    #expect(!m.canCollect(payload))
    #expect(m.isCollected(payload))
    #expect(!m.canCollect(m.dragPayload(for: tree.root)))
}

@Test @MainActor func commandDeleteRemovesHoveredPanelRow() async throws {
    let s = Scratch()
    s.file("a/x.bin", bytes: 8192)
    s.file("b/y.bin", bytes: 4096)
    let session = await scannedSession(s)
    let m = model(session)
    let tree = try #require(session.tree)
    let a = try #require(tree.node(atPath: s.path + "/a"))
    m.collect([a])
    m.viewDidChange()
    m.collectorPanelOpen = true
    m.panelHovered = a
    m.toggleCollected()
    #expect(m.view.collected.isEmpty)
    // The panel closes once the collector is empty.
    m.viewDidChange()
    #expect(!m.collectorPanelOpen)
    #expect(m.panelHovered == nil)
}

@Test @MainActor func collectorCircleIsInTabCycleWhenNonEmpty() async throws {
    let s = Scratch()
    s.file("a/x.bin", bytes: 8192)
    s.file("b/y.bin", bytes: 4096)
    let session = await scannedSession(s)
    let m = model(session)
    #expect(m.toolbarItem(after: nil, backwards: false) != .collector)
    let a = try #require(session.tree?.node(atPath: s.path + "/a"))
    m.collect([a])
    m.viewDidChange()
    #expect(m.toolbarItem(after: nil, backwards: false) == .collector)
}

@Test @MainActor func contextMenusOfferCollectorItems() async throws {
    let s = Scratch()
    s.file("a/x.bin", bytes: 8192)
    let session = await scannedSession(s)
    let m = model(session)
    let a = try #require(session.tree?.node(atPath: s.path + "/a"))
    let actions = ResultActions(model: m, router: nil)
    let move = try #require(actions.contextItems(for: a).last)
    #expect(move.title == "Move “a” to Collector")
    move.action()
    #expect(m.view.collected == [a])
    #expect(actions.collectorItems(for: a).map(\.title)
        == ["Preview", "Show in Finder", "Open in Terminal", "Remove “a” from Collector"])
    actions.collectorItems(for: a).last?.action()
    #expect(m.view.collected.isEmpty)
}
