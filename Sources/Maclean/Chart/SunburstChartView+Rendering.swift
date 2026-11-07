import AppKit
import MacleanCore
import MacleanKit
import QuartzCore
import SwiftUI

extension SunburstChartView {
    // MARK: Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidateCache()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        invalidateCache()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        invalidateCache()
        shownHighlight = nil   // geometry changed: rebuild the highlight path
        updateHighlightLayer(animated: false)
        invalidateAccessibility()
    }

    func invalidateCache() {
        cacheValid = false
        colorCache.removeAll()
        frameContext = nil
        needsDisplay = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = appearanceKind == .dark
            highlightLayer.fillColor = CGColor(gray: 1, alpha: dark ? 0.28 : 0.45)
            highlightLayer.strokeColor = NSColor.labelColor
                .withAlphaComponent(highContrast ? 0.85 : dark ? 0.5 : 0.35).cgColor
            highlightLayer.lineWidth = highContrast ? 1.5 : 1
            centreLayer.fillColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        }
    }

    var appearanceKind: Appearance {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    var highContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }

    struct ColorKey: Hashable {
        let kind: SegmentKind
        let hue: Int
        let ring: Int
    }

    func color(for s: Segment) -> CGColor {
        let hue = s.kind == .folder ? ((s.topLevelIndex % Palette.hueCount) + Palette.hueCount) % Palette.hueCount : 0
        let key = ColorKey(kind: s.kind, hue: hue, ring: min(s.ring, SunburstLayout.maxRings))
        if let c = colorCache[key] { return c }
        let rgb = Palette.color(kind: s.kind, topLevelIndex: hue, ring: key.ring,
                                appearance: appearanceKind, highContrast: highContrast)
        let alpha: CGFloat = s.kind == .smallerObjects ? 0.6 : 1
        let c = CGColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: alpha)
        colorCache[key] = c
        return c
    }

    // MARK: Drawing

    override func updateLayer() {
        guard let backing = layer, let chartLayout, !bounds.isEmpty else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        backing.contentsScale = scale
        let g = geometry
        let now = CACurrentMediaTime()

        if var t = transition {
            let drawStart = Timings.now
            let raw = min(max((now - t.start) / t.duration, 0), 1)
            let e = CGFloat(raw < 0.5 ? 2 * raw * raw : 1 - pow(-2 * raw + 2, 2) / 2)   // ease-in-out
            let image = render(into: &frameContext, scale: scale) { ctx in
                drawTransition(t, progress: e, to: chartLayout, in: ctx, geometry: g)
            }
            backing.contents = image
            showingCache = false
            t.frames += 1
            if t.frames > 1 { Timings.mark("frameInterval", (now - t.lastFrame) * 1000) }
            t.lastFrame = now
            transition = t
            Timings.mark("frame", (Timings.now - drawStart) * 1000)
        } else if !cacheValid || !showingCache {
            if !cacheValid {
                cacheValid = true
                var context: CGContext?
                cache = render(into: &context, scale: scale) { ctx in
                    drawDisc(in: ctx, geometry: g)
                    drawSegments(chartLayout.segments, in: ctx, geometry: g) { s in
                        (Double(s.ring), s.startAngle, s.endAngle)
                    }
                    drawLabels(title: title, subtitle: subtitle, alpha: 1, geometry: g)
                }
            }
            backing.contents = cache
            showingCache = true
            updateHighlightLayer(animated: false)
        }

        if !firstFrameDone {
            firstFrameDone = true
            onFirstFrame?()
        }
    }

    /// Renders into a bitmap at backing scale in the view's (flipped)
    /// coordinates, reusing `context` while its size matches.
    func render(into context: inout CGContext?, scale: CGFloat, _ body: (CGContext) -> Void) -> CGImage? {
        let width = Int((bounds.width * scale).rounded(.up)), height = Int((bounds.height * scale).rounded(.up))
        guard width > 0, height > 0 else { return nil }
        if context == nil || context?.width != width || context?.height != height {
            context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let ctx = context else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        effectiveAppearance.performAsCurrentDrawingAppearance { body(ctx) }
        NSGraphicsContext.current = previous
        ctx.restoreGState()
        return ctx.makeImage()
    }

    var gap: CGFloat { Palette.segmentGap(appearance: appearanceKind, highContrast: highContrast) }

    /// Fills (or, for mount points, outlines) `segments`, one path per colour.
    /// `place` gives each segment's (ring position, start, end), possibly mid-animation.
    func drawSegments(_ segments: [Segment], in ctx: CGContext, geometry g: Geometry,
                              place: (Segment) -> (Double, Double, Double)) {
        let gap = self.gap
        var fills: [CGColor: CGMutablePath] = [:]
        var outlines: [CGColor: CGMutablePath] = [:]
        let maxRing = Double(SunburstLayout.maxRings) + 1
        for s in segments {
            let (ring, a0, a1) = place(s)
            guard ring < maxRing, a1 > a0 else { continue }
            let c = color(for: s)
            let path: CGMutablePath
            if s.kind == .mountPoint {
                if let p = outlines[c] { path = p } else { path = CGMutablePath(); outlines[c] = path }
            } else {
                if let p = fills[c] { path = p } else { path = CGMutablePath(); fills[c] = path }
            }
            addSegment(to: path, geometry: g, ringPosition: CGFloat(ring), a0: a0, a1: a1, gap: gap)
        }
        for (c, path) in fills {
            ctx.addPath(path)
            ctx.setFillColor(c)
            ctx.fillPath()
        }
        ctx.setLineWidth(1)
        for (c, path) in outlines {
            ctx.addPath(path)
            ctx.setStrokeColor(c)
            ctx.strokePath()
        }
    }

    /// An annular sector with a constant-width gap around it. Angles: 0 = 12
    /// o'clock, clockwise; the gap's angular share is capped so slivers stay visible.
    func addSegment(to path: CGMutablePath, geometry g: Geometry, ringPosition: CGFloat,
                            a0: Double, a1: Double, gap: CGFloat) {
        let ri = g.innerRadius(ringPosition: ringPosition) + gap / 2
        let ro = ri + g.ringWidth - gap
        guard ro > ri, ri > 0 else { return }
        let span = a1 - a0
        let quarter = Double.pi / 2
        if span >= 2 * .pi - 1e-6 {
            // A single child filling the ring: a full annulus (inner circle reversed).
            // Each subpath starts with a move: `addArc` would otherwise join it to the previous one.
            path.move(to: CGPoint(x: g.center.x + ro, y: g.center.y))
            path.addArc(center: g.center, radius: ro, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            path.closeSubpath()
            path.move(to: CGPoint(x: g.center.x + ri, y: g.center.y))
            path.addArc(center: g.center, radius: ri, startAngle: 2 * .pi, endAngle: 0, clockwise: true)
            path.closeSubpath()
            return
        }
        let dOuter = min(Double(gap / 2 / ro), span * 0.3)
        let dInner = min(Double(gap / 2 / ri), span * 0.3)
        let start = a0 + dOuter - quarter
        path.move(to: CGPoint(x: g.center.x + ro * cos(start), y: g.center.y + ro * sin(start)))
        path.addArc(center: g.center, radius: ro, startAngle: a0 + dOuter - quarter,
                    endAngle: a1 - dOuter - quarter, clockwise: false)
        path.addArc(center: g.center, radius: ri, startAngle: a1 - dInner - quarter,
                    endAngle: a0 + dInner - quarter, clockwise: true)
        path.closeSubpath()
    }

    func discRect(_ g: Geometry) -> CGRect {
        CGRect(x: g.center.x - g.discRadius, y: g.center.y - g.discRadius,
               width: 2 * g.discRadius, height: 2 * g.discRadius)
    }

    func drawDisc(in ctx: CGContext, geometry g: Geometry) {
        let dark = appearanceKind == .dark
        ctx.setFillColor(NSColor.labelColor.withAlphaComponent(dark ? 0.07 : 0.035).cgColor)
        ctx.fillEllipse(in: discRect(g))
    }

    /// Size (large, never truncated: the font shrinks to fit, down to 13 pt) over the name
    /// (small, truncated in the middle).
    func drawLabels(title: String, subtitle: String, alpha: CGFloat, geometry g: Geometry) {
        guard alpha > 0.01 else { return }
        let width = g.discRadius * 1.5
        var titleSize: CGFloat = min(26, max(15, g.discRadius * 0.3))
        var titleAttrs: [NSAttributedString.Key: Any] = [:]
        var titleWidth: CGFloat = 0
        repeat {
            titleAttrs = [.font: NSFont.monospacedDigitSystemFont(ofSize: titleSize, weight: .semibold),
                          .foregroundColor: NSColor.labelColor.withAlphaComponent(alpha)]
            titleWidth = (title as NSString).size(withAttributes: titleAttrs).width
            titleSize -= 1
        } while titleWidth > width && titleSize >= 13   // never below 13 pt (may overhang the disc)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            // Increase Contrast: full-contrast text.
            .foregroundColor: (highContrast ? NSColor.labelColor : NSColor.secondaryLabelColor)
                .withAlphaComponent(alpha),
            .paragraphStyle: paragraph,
        ]
        let titleHeight = (titleAttrs[.font] as? NSFont).map { $0.ascender - $0.descender + $0.leading } ?? 24
        let subHeight: CGFloat = 17
        let top = g.center.y - (titleHeight + 2 + subHeight) / 2
        (title as NSString).draw(at: CGPoint(x: g.center.x - titleWidth / 2, y: top), withAttributes: titleAttrs)
        (subtitle as NSString).draw(with: CGRect(x: g.center.x - width / 2, y: top + titleHeight + 2,
                                                 width: width, height: subHeight),
                                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                    attributes: subAttrs)
    }
}
