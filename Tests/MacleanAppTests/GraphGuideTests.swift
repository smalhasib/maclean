import CoreGraphics
import Foundation
import Testing
import MacleanCore
@testable import Maclean

// The first-scan walkthrough of the chart: shown once on its own, and again from Help.

@MainActor private func guideModel(_ session: ScanSession, defaults: UserDefaults) -> ResultViewModel {
    ResultViewModel(session: session, ownsSessionHistory: false, defaults: defaults)
}

private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "guide-\(UUID().uuidString)")! }

@Test @MainActor func theGuideShowsItselfOnceOnTheFirstResult() async {
    let s = Scratch(); s.file("a.bin", bytes: 4096)
    let session = await scannedSession(s)
    let defaults = freshDefaults()

    let first = guideModel(session, defaults: defaults)
    #expect(first.guideStep == nil)
    first.showGuideIfFirstTime()
    #expect(first.guideStep == 0)

    // Seen as soon as it is shown: closing the window half way doesn't bring it back.
    let second = guideModel(session, defaults: defaults)
    second.showGuideIfFirstTime()
    #expect(second.guideStep == nil)
}

@Test @MainActor func helpCanShowTheGuideAgainAnyTime() async {
    let s = Scratch(); s.file("a.bin", bytes: 4096)
    let session = await scannedSession(s)
    let defaults = freshDefaults()
    let m = guideModel(session, defaults: defaults)
    m.showGuideIfFirstTime()
    m.endGuide()
    #expect(m.guideStep == nil)

    m.startGuide()
    #expect(m.guideStep == 0)
}

@Test @MainActor func stepsMoveForwardAndBackAndFinish() async {
    let s = Scratch(); s.file("a.bin", bytes: 4096)
    let session = await scannedSession(s)
    let m = guideModel(session, defaults: freshDefaults())
    m.startGuide()
    m.guideBack()
    #expect(m.guideStep == 0)               // not before the first step
    m.guideNext()
    m.guideNext()
    #expect(m.guideStep == 2)
    m.guideBack()
    #expect(m.guideStep == 1)
    for _ in 0..<GraphGuide.steps.count { m.guideNext() }
    #expect(m.guideStep == nil)             // Next on the last step is Done
}

@Test @MainActor func skippingEndsItAtOnceAndKeepsItSeen() async {
    let s = Scratch(); s.file("a.bin", bytes: 4096)
    let session = await scannedSession(s)
    let defaults = freshDefaults()
    let m = guideModel(session, defaults: defaults)
    m.showGuideIfFirstTime()
    m.guideNext()
    m.endGuide()
    #expect(m.guideStep == nil)
    let again = guideModel(session, defaults: defaults)
    again.showGuideIfFirstTime()
    #expect(again.guideStep == nil)
}

@Test func everyStepSaysWhatToDoAndPointsAtSomething() {
    let steps = GraphGuide.steps
    #expect(steps.count == 6)
    for step in steps {
        #expect(!step.title.isEmpty)
        #expect(step.body.count > 20)
    }
    #expect(Set(steps.map(\.focus)).count == 6)   // each step spotlights a different place
    #expect(steps.first?.focus == .chart)
    #expect(steps.last?.focus == .collector)
}

@Test @MainActor func guidePaddingMatchesTheChart() {
    #expect(GraphGuide.chartPadding == SunburstChartView.padding)
}

@Test func chartSpotlightsMatchTheChartsOwnGeometry() {
    // Same rules as SunburstChartView.geometry: padded square, inner radius 27% (at least 40), disc 3pt inside it.
    let frame = CGRect(x: 10, y: 20, width: 600, height: 400)
    let g = GraphGuide.chartGeometry(in: frame)
    #expect(g.center == CGPoint(x: 310, y: 220))
    #expect(g.outer == CGFloat(400 - 2 * 24) / 2)
    #expect(g.inner == max(g.outer * 0.27, 40))
    #expect(g.disc == g.inner - 3)

    let tiny = GraphGuide.chartGeometry(in: CGRect(x: 0, y: 0, width: 100, height: 100))
    #expect(tiny.inner >= 40)
}

@Test @MainActor func theGuideSurvivesTheWindowGettingAFreshTree() async throws {
    // A rescan, or the password read that adds the locked folders, gives the window a new model.
    // The guide used to vanish mid-way because its step lived only in the old one.
    let s = Scratch(); s.file("a.bin", bytes: 4096)
    let session = await scannedSession(s)
    let cache = ResultModelCache(ownsSessionHistory: false)
    let first = try #require(cache.model(for: session, tree: session.tree))
    first.startGuide()
    first.guideNext()
    first.guideNext()
    #expect(first.guideStep == 2)

    session.rescan()
    while session.isScanning { try? await Task.sleep(for: .milliseconds(10)) }
    let second = try #require(cache.model(for: session, tree: session.tree))
    #expect(second !== first)           // really a different model
    #expect(second.guideStep == 2)      // and the guide is still where it was
}

@Test @MainActor func rescanWaitsWhileTheGuideIsShowing() async throws {
    // The guide covers the window; a Rescan chosen from the menu meanwhile would send the window
    // back to the start screen under it and leave it small.
    let s = Scratch(); s.file("a.bin", bytes: 4096)
    let registry = SessionRegistry()
    registry.startScan(path: s.path)
    let session = try #require(registry.session(canonical: ScanBoundary.canonicalPath(s.path)!))
    while session.isScanning { try? await Task.sleep(for: .milliseconds(10)) }
    let router = WindowRouter(registry: registry,
                              startModel: StartModel(defaults: UserDefaults(suiteName: "g-\(UUID().uuidString)")!))
    let m = ResultViewModel(session: session, ownsSessionHistory: false, defaults: freshDefaults())

    m.startGuide()
    router.rescan(m)
    #expect(!session.isScanning)        // ignored while the guide is up

    m.endGuide()
    router.rescan(m)
    #expect(session.isScanning)         // and works again once it's done
    while session.isScanning { try? await Task.sleep(for: .milliseconds(10)) }
}
