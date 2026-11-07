import Foundation
import Testing
import MacleanCore
import MacleanKit
@testable import Maclean

@MainActor private func rescanned(_ session: ScanSession) async {
    session.rescan()
    while session.isScanning { try? await Task.sleep(for: .milliseconds(10)) }
}

@Test @MainActor func collectHidesInAllModelsOfSession() async throws {
    let s = Scratch()
    s.file("a/x.bin", bytes: 64 * 1024)
    s.file("b/y.bin", bytes: 32 * 1024)
    let session = await scannedSession(s)
    let m1 = model(session), m2 = model(session)
    let tree = try #require(session.tree)
    let a = try #require(tree.node(atPath: s.path + "/a"))
    #expect(m1.view.children(of: m1.listTarget).contains(a))

    #expect(session.collect([a]).isEmpty)
    m1.viewDidChange()
    m2.viewDidChange()
    for m in [m1, m2] {
        #expect(!m.view.children(of: m.listTarget).contains(a))
        #expect(m.listRowCount == 1)
        #expect(m.layout.segments.allSatisfy { $0.node != a })
        #expect(m.view.size(of: tree.root) == tree.size(of: tree.root) - tree.size(of: a))
    }
}

@Test @MainActor func refusedCollectReturnsReason() async throws {
    let s = Scratch()
    s.file("h/x.bin", bytes: 4096)
    s.file("k/y.bin", bytes: 4096)
    let session = await scannedSession(s)
    let tree = try #require(session.tree)
    session.protection.home = s.path + "/h"
    let h = try #require(tree.node(atPath: s.path + "/h"))
    let k = try #require(tree.node(atPath: s.path + "/k"))

    let refusals = session.collect([h])
    #expect(refusals.count == 1)
    #expect(refusals.first?.0 == h)
    #expect(refusals.first?.1 == .homeItself)
    #expect(session.view?.collected.isEmpty == true)

    // A refused id doesn't stop the others in the batch.
    #expect(session.collect([h, k]).map(\.0) == [h])
    #expect(session.view?.collected == [k])
}

@Test @MainActor func rescanCarriesOverByPath() async throws {
    let s = Scratch()
    s.file("a/x.bin", bytes: 8192)
    s.file("b/y.bin", bytes: 8192)
    s.file("c/z.bin", bytes: 8192)
    let session = await scannedSession(s)
    let old = try #require(session.tree)
    let oldA = try #require(old.node(atPath: s.path + "/a"))
    let oldB = try #require(old.node(atPath: s.path + "/b"))
    session.collect([oldA, oldB])
    let oldSize = old.size(of: oldA)

    s.remove("b")
    s.file("a/more.bin", bytes: 64 * 1024)
    await rescanned(session)

    let tree = try #require(session.tree)
    let view = try #require(session.view)
    #expect(view.tree === tree)
    #expect(view.collected.map { tree.path(of: $0) } == [s.path + "/a"])
    #expect(session.carryOverDropped == 1)
    let a = try #require(tree.node(atPath: s.path + "/a"))
    #expect(tree.size(of: a) > oldSize)
    #expect(view.size(of: tree.root) == tree.size(of: tree.root) - tree.size(of: a))
    #expect(view.removed.isEmpty)

    session.clearCarryOverDropped()
    #expect(session.carryOverDropped == nil)
}

@Test @MainActor func rescanWithNothingDroppedLeavesNoNote() async throws {
    let s = Scratch()
    s.file("a/x.bin", bytes: 8192)
    s.file("c/z.bin", bytes: 8192)
    let session = await scannedSession(s)
    session.collect([try #require(session.tree?.node(atPath: s.path + "/a"))])
    await rescanned(session)
    #expect(session.carryOverDropped == nil)
    #expect(session.view?.collected.count == 1)
}

@Test @MainActor func collectIsNoOpWhileDeleting() async throws {
    let s = Scratch()
    s.file("a/x.bin", bytes: 4096)
    s.file("b/y.bin", bytes: 4096)
    let session = await scannedSession(s)
    let tree = try #require(session.tree)
    let a = try #require(tree.node(atPath: s.path + "/a"))
    let b = try #require(tree.node(atPath: s.path + "/b"))
    session.collect([a])
    let generation = session.view?.generation
    session.isDeleting = true
    #expect(session.collect([b]).isEmpty)
    #expect(session.view?.collected == [a])
    #expect(session.view?.generation == generation)
}

@Test @MainActor func currentFolderHiddenNavigatesUp() async throws {
    let s = Scratch()
    s.file("a/b/x.bin", bytes: 4096)
    s.file("c/y.bin", bytes: 4096)
    let session = await scannedSession(s)
    let m1 = model(session), m2 = model(session)
    m1.visit(path: s.path + "/a/b")
    let tree = m1.tree
    let a = try #require(tree.node(atPath: s.path + "/a"))
    m2.toggleCollected(a)
    #expect(session.view?.collected == [a])
    m1.viewDidChange()
    m2.viewDidChange()
    #expect(m1.currentNode == tree.root)
    #expect(m1.history.current == s.path)
    // Back to the hidden folder lands on a visible ancestor too.
    m1.back()
    #expect(m1.currentNode == tree.root)
}

@Test @MainActor func cmdDeleteOnSmallerObjectsRefuses() async throws {
    let s = Scratch()
    s.file("big.bin", bytes: 8 * 1024 * 1024)
    for i in 0 ..< 3 { s.file("tiny\(i).bin", bytes: 1) }
    let session = await scannedSession(s)
    let m = model(session)
    let tree = m.tree
    let smaller = try #require(m.layout.segments.first { $0.node == nil })
    m.hover(nil, from: .chart, smallerObjectsOf: smaller.parent)
    m.selected = tree.node(atPath: s.path + "/big.bin")
    m.toggleCollected()
    #expect(m.collectorRefusal?.text == "“smaller objects” is a group. Expand it and collect the items inside.")
    #expect(session.view?.collected.isEmpty == true)
}

@Test @MainActor func toggleCollectedActsOnActionTargetOnly() async throws {
    let s = Scratch()
    s.file("a/b/x.bin", bytes: 4096)
    s.file("c/y.bin", bytes: 4096)
    let session = await scannedSession(s)
    let m = model(session)
    m.visit(path: s.path + "/a")
    // Nothing hovered or selected: the current folder is not collected.
    m.toggleCollected()
    #expect(session.view?.collected.isEmpty == true)

    let b = try #require(m.tree.node(atPath: s.path + "/a/b"))
    m.selected = b
    m.toggleCollected()
    #expect(session.view?.collected == [b])
    m.viewDidChange()
    #expect(m.selected == nil)
    // Toggling a collected item puts it back.
    m.toggleCollected(b)
    #expect(session.view?.collected.isEmpty == true)
}

@Test @MainActor func toggleRefusalSetsNotice() async throws {
    let s = Scratch()
    s.file("h/x.bin", bytes: 4096)
    let session = await scannedSession(s)
    session.protection.home = s.path + "/h"
    let m = model(session)
    let h = try #require(m.tree.node(atPath: s.path + "/h"))
    m.toggleCollected(h)
    #expect(m.collectorRefusal?.text == Refusal.homeItself.message(name: "h"))
}

@Test @MainActor func hiddenChildrenAreNotSelectable() async throws {
    let s = Scratch()
    s.file("a/x.bin", bytes: 64 * 1024)
    s.file("b/y.bin", bytes: 32 * 1024)
    s.file("c/z.bin", bytes: 16 * 1024)
    let session = await scannedSession(s)
    let m = model(session)
    let tree = m.tree
    let a = try #require(tree.node(atPath: s.path + "/a"))
    session.collect([a])
    m.viewDidChange()
    m.moveSelection(.home)
    #expect(m.selected == tree.node(atPath: s.path + "/b"))
    m.moveSelection(.end)
    #expect(m.selected == tree.node(atPath: s.path + "/c"))
    m.selected = nil
    m.traverse(.next)
    #expect(m.selected == tree.node(atPath: s.path + "/b"))
    m.traverse(.previous)
    #expect(m.selected == tree.node(atPath: s.path + "/b"))
}

@Test @MainActor func forgetClearsCollector() async throws {
    let s = Scratch()
    s.file("a/x.bin", bytes: 4096)
    let registry = SessionRegistry()
    let session = registry.startScan(path: s.path)
    while session.isScanning { try await Task.sleep(for: .milliseconds(10)) }
    session.collect([try #require(session.tree?.node(atPath: s.path + "/a"))])
    #expect(session.view?.collected.count == 1)
    registry.forget(path: session.rootPath)
    #expect(session.view?.collected.isEmpty == true)
}

@Test @MainActor func morphPlanMatchesByNodeAndCollapsesVanished() async throws {
    // Root → a (2 units), b (1), c (1); collecting b leaves a and c.
    let s = Scratch()
    s.file("a/x.bin", bytes: 2 * 64 * 1024)
    s.file("b/y.bin", bytes: 64 * 1024)
    s.file("c/z.bin", bytes: 64 * 1024)
    let session = await scannedSession(s)
    let tree = try #require(session.tree)
    var view = TreeView(tree: tree)
    let old = SunburstLayout(view: view, root: tree.root)
    let b = try #require(tree.node(atPath: s.path + "/b"))
    view.collect([b])
    let new = SunburstLayout(view: view, root: tree.root)
    let plan = SunburstChartView.morphPlan(from: old, to: new)

    // Surviving segments start at their old angles.
    for seg in new.segments {
        let key = SunburstChartView.MorphKey(seg)
        let start = try #require(plan.start[key])
        let o = try #require(old.segments.first { SunburstChartView.MorphKey($0) == key })
        #expect(start.a0 == o.startAngle && start.a1 == o.endAngle)
    }
    // b and its child vanish, shrinking to the angle where b's slot closes.
    let vanishedB = try #require(plan.vanished.first { $0.segment.node == b })
    let aNew = try #require(new.segments.first { $0.node == tree.node(atPath: s.path + "/a") })
    #expect(abs(vanishedB.angle - aNew.endAngle) < 1e-9)
    let child = try #require(plan.vanished.first { $0.segment.parent == b })
    #expect(child.angle == vanishedB.angle)

    // The reverse (uncollect): b grows from zero width at that same angle.
    let back = SunburstChartView.morphPlan(from: new, to: old)
    let grow = try #require(back.start[.node(b)])
    #expect(grow.a0 == grow.a1 && abs(grow.a0 - aNew.endAngle) < 1e-9)
    #expect(back.vanished.isEmpty)
}
