import Testing
@testable import MacleanKit

@Suite struct PaletteTests {
    @Test func neighbouringHuesDifferInLightness() {
        for hc in [false, true] { for a in [Appearance.light, .dark] { for ring in 1...5 { for i in 0..<Palette.hueCount {
            let x = Palette.color(kind: .folder, topLevelIndex: i, ring: ring, appearance: a, highContrast: hc)
            let y = Palette.color(kind: .folder, topLevelIndex: (i + 1) % Palette.hueCount, ring: ring, appearance: a, highContrast: hc)
            let need = ring <= 3 ? 0.04 : 0.02
            #expect(abs(x.relativeLuminance - y.relativeLuminance) >= need, "hue \(i) ring \(ring) \(a) hc=\(hc)")
        } } } }
    }

    @Test func ringsLightenInLightDarkenInDark() {
        for hc in [false, true] { for i in 0..<Palette.hueCount { for a in [Appearance.light, .dark] {
            let lums = (1...5).map { Palette.color(kind: .folder, topLevelIndex: i, ring: $0, appearance: a, highContrast: hc).relativeLuminance }
            for (p, n) in zip(lums, lums.dropFirst()) {
                #expect(a == .light ? n > p : n < p, "hue \(i) \(a) hc=\(hc) \(lums)")
            }
        } } }
    }

    @Test func hueRepeatsAfterEight() {
        #expect(Palette.color(kind: .folder, topLevelIndex: 1, ring: 2, appearance: .light)
                == Palette.color(kind: .folder, topLevelIndex: 9, ring: 2, appearance: .light))
    }

    @Test func filesAreGreyAndRestrictedPurple() {
        for a in [Appearance.light, .dark] {
            let f = Palette.color(kind: .file, topLevelIndex: 3, ring: 2, appearance: a)
            #expect(abs(f.r - f.g) < 0.01 && abs(f.g - f.b) < 0.01)
            #expect(Palette.color(kind: .package, topLevelIndex: 3, ring: 2, appearance: a) == f)
            let r = Palette.color(kind: .restricted, topLevelIndex: 0, ring: 1, appearance: a)
            #expect(r.b > r.g)
            let s = Palette.color(kind: .smallerObjects, topLevelIndex: 0, ring: 1, appearance: .light)
            #expect(s.relativeLuminance > Palette.color(kind: .file, topLevelIndex: 0, ring: 1, appearance: .light).relativeLuminance)
        }
    }

    @Test func gaps() {
        #expect(Palette.segmentGap(appearance: .light, highContrast: false) == 1.5)
        #expect(Palette.segmentGap(appearance: .dark, highContrast: false) == 2.0)
        #expect(Palette.segmentGap(appearance: .light, highContrast: true) > 1.5)
        #expect(Palette.segmentGap(appearance: .dark, highContrast: true) > 2.0)
    }
}
