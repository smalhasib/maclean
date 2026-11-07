import Testing
@testable import MacleanKit

@Suite struct PaletteTests {
    @Test func neighbouringHuesDifferInLightness() {
        for hc in [false, true] { for a in [Appearance.light, .dark] { for i in 0..<Palette.hueCount {
            let x = Palette.color(kind: .folder, topLevelIndex: i, ring: 1, appearance: a, highContrast: hc)
            let y = Palette.color(kind: .folder, topLevelIndex: (i + 1) % Palette.hueCount, ring: 1, appearance: a, highContrast: hc)
            #expect(abs(x.relativeLuminance - y.relativeLuminance) >= 0.04, "hue \(i) \(a) hc=\(hc)")
        } } }
    }

    @Test func ringsLightenInLightDarkenInDark() {
        for i in 0..<Palette.hueCount {
            let l1 = Palette.color(kind: .folder, topLevelIndex: i, ring: 1, appearance: .light).relativeLuminance
            let l3 = Palette.color(kind: .folder, topLevelIndex: i, ring: 3, appearance: .light).relativeLuminance
            let d1 = Palette.color(kind: .folder, topLevelIndex: i, ring: 1, appearance: .dark).relativeLuminance
            let d3 = Palette.color(kind: .folder, topLevelIndex: i, ring: 3, appearance: .dark).relativeLuminance
            #expect(l3 > l1)
            #expect(d3 < d1)
        }
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
