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

    @Test func remapStopsAtRoot() {
        var h = NavigationHistory(rootPath: "/r")
        h.visit("/r/a/b")
        h.remap { _ in false }
        #expect(h.current == "/r")
        #expect(h.enclosing(rootPath: "/r") == nil)
        #expect(!h.canGoBack)
    }

    @Test func enclosingNeverLeavesRoot() {
        var h = NavigationHistory(rootPath: "/r/a")
        h.visit("/r/a/b")
        #expect(h.enclosing(rootPath: "/r/a") == "/r/a")
        h.visit("/r/a")
        #expect(h.enclosing(rootPath: "/r/a") == nil)
    }

    @Test func remapPrunesForwardStack() {
        var h = NavigationHistory(rootPath: "/r")
        h.visit("/r/a"); h.visit("/r/b"); h.visit("/r/c")
        h.back(); h.back(); h.back()           // current /r, forward [/r/c, /r/b, /r/a] (nearest last)
        h.remap { $0 == "/r" || $0 == "/r/a" }
        #expect(h.canGoForward)
        h.forward(); #expect(h.current == "/r/a")
        #expect(!h.canGoForward)
    }
}
