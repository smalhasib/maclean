import Foundation

public enum Appearance: Sendable { case light, dark }

/// sRGB, components 0...1.
public struct RGB: Sendable, Equatable {
    public let r, g, b: Double
    public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    /// WCAG 2.x relative luminance.
    public var relativeLuminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// `h` in degrees, `s` and `l` in 0...1.
    static func hsl(_ h: Double, _ s: Double, _ l: Double) -> RGB {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double)
        switch hp {
        case ..<1: (r1, g1, b1) = (c, x, 0)
        case ..<2: (r1, g1, b1) = (x, c, 0)
        case ..<3: (r1, g1, b1) = (0, c, x)
        case ..<4: (r1, g1, b1) = (0, x, c)
        case ..<5: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        let m = l - c / 2
        return RGB(r: r1 + m, g: g1 + m, b: b1 + m)
    }
}

/// Colour rules for the sunburst ("light & airy": pastel hues with thin gaps).
///
/// Folders use 8 ordered hues (blue, green, orange, purple, pink, teal, yellow,
/// indigo; repeating by `topLevelIndex`). Ring 1 colours come from the table
/// below in HSL; every further ring goes lighter and less saturated in light
/// mode (+5 L, -8 S per ring) and darker and less saturated in dark mode
/// (-8 L, -6 S per ring), mirroring the mockup (`hsl(h 70-8d% 74+5d%)` light,
/// `hsl(h 62-6d% 66-8d%)` dark). Per-hue lightness is nudged from the mockup
/// baseline (light 74, dark 66) so that adjacent hues, including indigo->blue at
/// the wrap, differ in relative luminance by >= 0.04 in both appearances
/// (measured minimum ~0.049, ring 1; luminances in the task report). High
/// contrast adds +15 S and shifts L by -10 (light) / +8 (dark).
public enum Palette {
    public static let hueCount = 8

    // hue, light-mode ring-1 lightness %, dark-mode ring-1 lightness %
    private static let hues: [(h: Double, light: Double, dark: Double)] = [
        (212, 68, 58),  // blue
        (152, 78, 70),  // green
        (32, 70, 62),   // orange
        (280, 68, 58),  // purple
        (340, 80, 70),  // pink
        (190, 72, 64),  // teal
        (48, 84, 76),   // yellow
        (260, 72, 64),  // indigo
    ]

    public static func color(kind: SegmentKind, topLevelIndex: Int, ring: Int,
                             appearance: Appearance, highContrast: Bool = false) -> RGB {
        let light = appearance == .light
        let d = Double(max(0, min(ring, 5) - 1))
        let hc = highContrast
        switch kind {
        case .folder:
            let i = ((topLevelIndex % hueCount) + hueCount) % hueCount
            let e = hues[i]
            var s = (light ? 70 - 8 * d : 62 - 6 * d)
            var l = (light ? e.light + 5 * d : e.dark - 8 * d)
            if hc { s += 15; l += light ? -10 : 8 }   // stronger, more saturated colour
            return .hsl(e.h, max(s, 8) / 100, min(max(l, 8), 94) / 100)
        case .file, .package:
            return grey(light ? 80 - 2 * d : 38 + 4 * d, hc: hc, light: light)
        case .mountPoint:
            return grey(light ? 70 : 52, hc: hc, light: light)
        case .smallerObjects:
            return grey(light ? 90 : 28, hc: hc, light: light)
        case .restricted:
            return .hsl(270, hc ? 0.35 : 0.22, (light ? (hc ? 55 : 72) : (hc ? 62 : 52)) / 100)
        }
    }

    /// Gap between segments in points: 1.5 (light) / 2.0 (dark), thicker with high contrast.
    public static func segmentGap(appearance: Appearance, highContrast: Bool) -> Double {
        let base = appearance == .light ? 1.5 : 2.0
        return highContrast ? base + 1.0 : base
    }

    private static func grey(_ l: Double, hc: Bool, light: Bool) -> RGB {
        let v = min(max((hc ? l + (light ? -12 : 12) : l) / 100, 0), 1)
        return RGB(r: v, g: v, b: v)
    }
}
