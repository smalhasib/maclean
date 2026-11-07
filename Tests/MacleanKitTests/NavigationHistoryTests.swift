import Testing
@testable import MacleanKit

@Suite struct NavigationHistoryTests {
    @Test func historyBackForward() {
        var h = NavigationHistory(rootPath: "/a")
        h.visit("/b"); h.visit("/c")
        h.back(); #expect(h.current == "/b")
        h.back(); #expect(h.current == "/a")
        #expect(!h.canGoBack)
        h.forward(); #expect(h.current == "/b")
        h.visit("/d")
        #expect(!h.canGoForward)
        #expect(h.canGoBack)
    }

    @Test func enclosing() {
        var h = NavigationHistory(rootPath: "/r")
        #expect(h.enclosing(rootPath: "/r") == nil)
        h.visit("/r/a/b")
        #expect(h.enclosing(rootPath: "/r") == "/r/a")
        h.visit("/r/a")
        #expect(h.enclosing(rootPath: "/r") == "/r")
    }

    @Test func remapFallsBackToAncestor() {
        var h = NavigationHistory(rootPath: "/r")
        h.visit("/r/a"); h.visit("/r/a/x"); h.visit("/r/a/b/c")
        h.remap { $0 == "/r" || $0 == "/r/a" }
        #expect(h.current == "/r/a")
        h.back()  // /r/a/x removed and the duplicate /r/a collapsed
        #expect(h.current == "/r")
        #expect(!h.canGoBack)
    }
}
