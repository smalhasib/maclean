// Draws Maclean's app icon and builds Resources/AppIcon.icns.
//
//     swift scripts/make-icon.swift [preview.png]
//
// A pastel ring chart (the ring-1 hues of MacleanKit's Palette, light mode)
// on a soft white rounded square, drawn with Core Graphics at every iconset
// size, then packed with `iconutil -c icns`. Optionally also writes a 512 px
// PNG preview to the given path.
import AppKit
import Foundation

/// HSL (h in degrees, s and l in 0...1) to an sRGB colour.
func hsl(_ h: Double, _ s: Double, _ l: Double, alpha: Double = 1) -> CGColor {
    let c = (1 - abs(2 * l - 1)) * s
    let hp = h / 60
    let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
    let (r, g, b): (Double, Double, Double) = switch hp {
    case ..<1: (c, x, 0)
    case ..<2: (x, c, 0)
    case ..<3: (0, c, x)
    case ..<4: (0, x, c)
    case ..<5: (x, 0, c)
    default: (c, 0, x)
    }
    let m = l - c / 2
    return CGColor(srgbRed: r + m, green: g + m, blue: b + m, alpha: alpha)
}

// Palette ring-1 hues (light mode): blue, green, orange, purple, pink, teal, yellow, indigo.
let blue = (212.0, 0.69), green = (152.0, 0.80), orange = (32.0, 0.68), purple = (280.0, 0.63)
let pink = (340.0, 0.74), teal = (190.0, 0.73), yellow = (48.0, 0.80)

/// A ring of segments: (fraction of the circle, hue, lightness).
typealias Ring = [(share: Double, hue: (Double, Double))]

// Inner ring: four top-level folders, largest first from 12 o'clock.
let inner: Ring = [(0.38, blue), (0.26, green), (0.20, orange), (0.16, pink)]
// Outer ring: some children of each, lighter, with gaps where folders end shallow.
let outer: [(start: Double, end: Double, hue: (Double, Double))] = [
    (0.00, 0.22, blue), (0.22, 0.33, blue),
    (0.38, 0.53, green),
    (0.64, 0.76, orange),
    (0.84, 0.94, pink),
]

func draw(size px: Int) -> Data {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // macOS icon grid: an 824/1024 rounded square, centred, with a soft shadow.
    let inset = s * 100 / 1024
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let corner = tile.width * 0.225
    let tilePath = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)

    if px >= 64 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                      color: CGColor(gray: 0, alpha: 0.22))
        ctx.addPath(tilePath)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Tile: near-white with a faint cool gradient (light & airy).
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                                       CGColor(srgbRed: 0.925, green: 0.945, blue: 0.975, alpha: 1)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    ctx.restoreGState()

    // Hairline edge so the white tile holds its shape on white backgrounds.
    ctx.addPath(tilePath)
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.08))
    ctx.setLineWidth(max(s / 512, 0.5))
    ctx.strokePath()

    // Ring chart. At 16 and 32 px it becomes one thick, slightly deeper ring
    // with hairline gaps, so it still reads as a ring chart.
    let small = px <= 32
    let center = CGPoint(x: s / 2, y: s / 2)
    let radius = tile.width * (small ? 0.44 : 0.40)
    let hole = radius * (small ? 0.36 : 0.34)
    let split = small ? radius : radius * 0.68
    let gap = small ? s / 32 : max(s * 0.014, 0.75)
    let deepen = small ? 0.12 : 0.03

    func sector(_ r0: CGFloat, _ r1: CGFloat, _ f0: Double, _ f1: Double, _ color: CGColor) {
        // Fractions run clockwise from 12 o'clock; CG angles counter-clockwise from 3 o'clock.
        let a0 = CGFloat(.pi / 2 - f0 * 2 * .pi), a1 = CGFloat(.pi / 2 - f1 * 2 * .pi)
        let ri = r0 + gap / 2, ro = r1 - gap / 2
        let dOut = gap / 2 / ro, dIn = gap / 2 / ri
        let path = CGMutablePath()
        path.addArc(center: center, radius: ro, startAngle: a0 - dOut, endAngle: a1 + dOut, clockwise: true)
        path.addArc(center: center, radius: ri, startAngle: a1 + dIn, endAngle: a0 - dIn, clockwise: false)
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(color)
        ctx.fillPath()
    }

    var f = 0.0
    for seg in inner {
        sector(hole, split, f, f + seg.share, hsl(seg.hue.0, small ? 0.75 : 0.70, seg.hue.1 - deepen))
        f += seg.share
    }
    for seg in outer where !small {
        // One ring further out: lighter and a little less saturated, as in the app.
        sector(split, radius, seg.start, seg.end, hsl(seg.hue.0, 0.67, min(seg.hue.1 + 0.06 - deepen, 0.92)))
    }

    // Centre disc, as in the app.
    let disc = hole - gap
    ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.24, blue: 0.32, alpha: 0.05))
    ctx.fillEllipse(in: CGRect(x: center.x - disc, y: center.y - disc, width: 2 * disc, height: 2 * disc))

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appending(path: "Maclean-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for base in [16, 32, 128, 256, 512] {
    try draw(size: base).write(to: iconset.appending(path: "icon_\(base)x\(base).png"))
    try draw(size: base * 2).write(to: iconset.appending(path: "icon_\(base)x\(base)@2x.png"))
}

let output = root.appending(path: "Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")

if CommandLine.arguments.count > 1 {
    let preview = URL(fileURLWithPath: CommandLine.arguments[1])
    try draw(size: 512).write(to: preview)
    print("Wrote \(preview.path)")
}
