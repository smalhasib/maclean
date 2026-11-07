import Testing
@testable import MacleanCore

@Test func isInsideIsComponentWise() {
    #expect(PathUtil.isInside("/a/b", orEqualTo: "/a"))
    #expect(PathUtil.isInside("/a", orEqualTo: "/a"))
    #expect(!PathUtil.isInside("/ab", orEqualTo: "/a"))
    #expect(!PathUtil.isInside("/a", orEqualTo: "/a/b"))
    #expect(PathUtil.isInside("/anything/at/all", orEqualTo: "/"))
    #expect(PathUtil.isInside("/a/b", orEqualTo: "/a/"))
}
