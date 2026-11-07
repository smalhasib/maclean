import Testing
@testable import MacleanKit

@Suite struct SizeTextTests {
    @Test func sizeText() {
        #expect(SizeText.string(306_600_000_000) == "306.6 GB")
        #expect(SizeText.string(0) == "Zero KB")
    }

    @Test func spokenSize() {
        #expect(SizeText.spoken(307_600_000_000) == "307.6 gigabytes")
        #expect(SizeText.spoken(12_300_000) == "12.3 megabytes")
        #expect(SizeText.spoken(1_000_000_000_000) == "1 terabyte")
        #expect(SizeText.spoken(0) == "0 bytes")
    }
}
