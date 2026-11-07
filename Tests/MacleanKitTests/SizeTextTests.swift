import Testing
@testable import MacleanKit

@Suite struct SizeTextTests {
    @Test func sizeText() {
        #expect(SizeText.string(306_600_000_000) == "306.6 GB")
        #expect(SizeText.string(0) == "Zero KB")
    }
}
