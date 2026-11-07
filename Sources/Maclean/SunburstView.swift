import AppKit
import MacleanCore
import MacleanKit
import QuartzCore
import SwiftUI

/// The ring chart for a result. Reads the model in `body`, so SwiftUI tracks
/// exactly the properties the chart depends on.
struct SunburstView: View {
    let model: ResultViewModel

    var body: some View {
        let node = model.currentNode
        let listHover = model.hoverSource == .list ? model.hovered : nil
        SunburstRepresentable(
            model: model, layout: model.layout, generation: model.layoutGeneration,
            title: SizeText.string(model.tree.size(of: node)), subtitle: model.name(of: node),
            canGoUp: model.tree.parent(of: node) != nil,
            listHover: listHover, listHoverParent: listHover.flatMap { model.tree.parent(of: $0) })
    }
}

/// `SunburstChartView` (Core Graphics in an NSView) wrapped for SwiftUI.
private struct SunburstRepresentable: NSViewRepresentable {
    let model: ResultViewModel
    let layout: SunburstLayout
    let generation: Int
    let title: String
    let subtitle: String
    let canGoUp: Bool
    let listHover: NodeID?
    let listHoverParent: NodeID?

    func makeNSView(context: Context) -> SunburstChartView {
        let view = SunburstChartView()
        view.onHover = { [weak model] segment in
            model?.hover(segment?.node, from: .chart)
        }
        view.onClick = { [weak model] segment in
            guard let model, let node = segment.node else { return }
            if model.isDrillable(node) { model.open(node) } else { model.selected = node }
        }
        view.onCentreClick = { [weak model] in model?.goUp() }
        view.onFirstFrame = { [weak model] in model?.chartDidDrawFirstFrame() }
        apply(to: view, animated: false)
        return view
    }

    func updateNSView(_ view: SunburstChartView, context: Context) {
        apply(to: view, animated: true)
    }

    private func apply(to view: SunburstChartView, animated: Bool) {
        view.setContent(layout: layout, generation: generation, title: title, subtitle: subtitle,
                        canGoUp: canGoUp, animated: animated)
        // A list-row hover highlights its segment, or the "smaller objects"
        // segment it was merged into.
        view.setExternalHighlight(node: listHover, parent: listHoverParent)
    }
}

/// Draws `SunburstLayout.segments` as rings around a centre disc.
///
/// - The resting chart is rendered once into a bitmap (per layout, size,
///   appearance and contrast setting); hover frames draw that bitmap plus the
///   highlighted segment, so a hover costs one path fill.
/// - Navigation animates over 0.35 s (ease-in-out) on the view's display link:
///   drilling in, the new layout starts where its root sat in the old one
///   (angles and ring scaled into that slice) and sweeps out to full size while
///   the old layout fades; drilling out is the reverse. Unrelated jumps, and
///   all transitions with Reduce Motion on, crossfade.
/// - Segments are batched into one path per colour for drawing.
final class SunburstChartView: NSView {
    var onHover: ((Segment?) -> Void)?
    var onClick: ((Segment) -> Void)?
    var onCentreClick: (() -> Void)?
    var onFirstFrame: (() -> Void)?

    private static let animationDuration: TimeInterval = 0.35
    private static let crossfadeDuration: TimeInterval = 0.25
    private static let highlightFade: TimeInterval = 0.1
    private static let padding: CGFloat = 24

    private var layout: SunburstLayout?
    private var generation = -1
    private var title = ""
    private var subtitle = ""
    private var canGoUp = false

    private var hoverIndex: Int?
    private var externalIndex: Int?
    private var highlightedIndex: Int? { transition == nil ? (hoverIndex ?? externalIndex) : nil }
    private var highlightSince: TimeInterval = 0
    private var centreHovered = false
    private var pressedHit: Hit?
    private var pendingHoverTimestamp: TimeInterval?

    private struct Transition {
        enum Kind {
            /// The new root sat at `ring` / `a0..<a1` of the old layout.
            case zoomIn(ring: Int, a0: Double, a1: Double)
            /// The old root sits at `ring` / `a0..<a1` of the new layout.
            case zoomOut(ring: Int, a0: Double, a1: Double)
            case crossfade
        }
        let kind: Kind
        let from: SunburstLayout
        let fromTitle: String
        let fromSubtitle: String
        let start: TimeInterval
        let duration: TimeInterval
        var frames = 0
        var lastFrame: TimeInterval = 0
    }
    private var transition: Transition?
    private var link: CADisplayLink?

    private var cache: CGImage?
    private var cacheValid = false
    private var firstFrameDone = false
    private var trackingArea: NSTrackingArea?
    private var colorCache: [ColorKey: CGColor] = [:]
    // Read in deinit, which isn't main-actor isolated; written once in init.
    nonisolated(unsafe) private var accessibilityObserver: (any NSObjectProtocol)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidateCache() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Content

    func setContent(layout new: SunburstLayout, generation newGeneration: Int, title: String, subtitle: String,
                    canGoUp: Bool, animated: Bool) {
        self.canGoUp = canGoUp
        guard newGeneration != generation else { return }
        let old = layout
        let oldTitle = self.title, oldSubtitle = self.subtitle
        layout = new
        generation = newGeneration
        self.title = title
        self.subtitle = subtitle
        hoverIndex = nil
        externalIndex = nil
        invalidateCache()

        if animated, let old, window != nil, !bounds.isEmpty {
            startTransition(from: old, to: new, fromTitle: oldTitle, fromSubtitle: oldSubtitle)
        }
        // Re-evaluate what's under a resting pointer once the new chart is in.
        if transition == nil { refreshHoverFromMouse() }
    }

    func setExternalHighlight(node: NodeID?, parent: NodeID?) {
        var index: Int?
        if let node, let segments = layout?.segments {
            index = segments.firstIndex { $0.node == node }
            if index == nil, let parent {
                index = segments.firstIndex { $0.node == nil && $0.parent == parent }
            }
        }
        guard index != externalIndex else { return }
        externalIndex = index
        if hoverIndex == nil { highlightChanged() }
    }

    private func startTransition(from old: SunburstLayout, to new: SunburstLayout,
                                 fromTitle: String, fromSubtitle: String) {
        let kind: Transition.Kind
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            kind = .crossfade
        } else if let s = old.segments.first(where: { $0.node == new.root }) {
            kind = .zoomIn(ring: s.ring, a0: s.startAngle, a1: s.endAngle)
        } else if let s = new.segments.first(where: { $0.node == old.root }) {
            kind = .zoomOut(ring: s.ring, a0: s.startAngle, a1: s.endAngle)
        } else {
            kind = .crossfade
        }
        let duration: TimeInterval
        if case .crossfade = kind { duration = Self.crossfadeDuration } else { duration = Self.animationDuration }
        transition = Transition(kind: kind, from: old, fromTitle: fromTitle, fromSubtitle: fromSubtitle,
                                start: CACurrentMediaTime(), duration: duration)
        startLink()
        needsDisplay = true
    }

    // MARK: Display link

    private func startLink() {
        guard link == nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if let t = transition, now - t.start >= t.duration {
            finishTransition(now: now)
        }
        let fading = now - highlightSince < Self.highlightFade
        if transition == nil && !fading { stopLink() }
        needsDisplay = true
    }

    private func finishTransition(now: TimeInterval) {
        guard let t = transition else { return }
        if t.frames > 1 {
            let elapsed = t.lastFrame - t.start
            if elapsed > 0 { Timings.mark("drillFPS", Double(t.frames) / elapsed) }
        }
        transition = nil
        refreshHoverFromMouse()
    }

    // MARK: Geometry

    private struct Geometry {
        let center: CGPoint
        let outer: CGFloat
        let inner: CGFloat
        let ringWidth: CGFloat
        var discRadius: CGFloat { inner - 3 }

        func innerRadius(ringPosition p: CGFloat) -> CGFloat { inner + (p - 1) * ringWidth }
    }

    private var geometry: Geometry {
        let side = max(min(bounds.width, bounds.height) - 2 * Self.padding, 80)
        let outer = side / 2
        let inner = max(outer * 0.27, 40)
        return Geometry(center: CGPoint(x: bounds.midX, y: bounds.midY), outer: outer, inner: inner,
                        ringWidth: max((outer - inner) / CGFloat(SunburstLayout.maxRings), 1))
    }

    private enum Hit: Equatable { case segment(Int), centre, none }

    private func hit(at point: CGPoint) -> Hit {
        guard let layout else { return .none }
        let g = geometry
        let dx = Double(point.x - g.center.x), dy = Double(point.y - g.center.y)
        let r = (dx * dx + dy * dy).squareRoot()
        if r <= Double(g.discRadius) { return .centre }
        let angle = atan2(dx, -dy)   // 0 at 12 o'clock, clockwise (flipped view)
        guard let s = layout.segment(atRadius: r, angle: angle, innerRadius: Double(g.inner),
                                     ringWidth: Double(g.ringWidth)) else { return .none }
        // Segments are value types; find the one hit by its position in the ring.
        guard let i = layout.segments.firstIndex(where: {
            $0.ring == s.ring && $0.startAngle == s.startAngle
        }) else { return .none }
        return .segment(i)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited,
                                                         .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { updateHover(event: event) }
    override func mouseEntered(with event: NSEvent) { updateHover(event: event) }

    override func mouseExited(with event: NSEvent) {
        setHover(.none, timestamp: event.timestamp)
    }

    override func mouseDown(with event: NSEvent) {
        pressedHit = hit(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let h = hit(at: convert(event.locationInWindow, from: nil))
        defer { pressedHit = nil }
        guard h == pressedHit, transition == nil, let layout else { return }
        switch h {
        case .centre: if canGoUp { onCentreClick?() }
        case .segment(let i): onClick?(layout.segments[i])
        case .none: break
        }
    }

    private func updateHover(event: NSEvent) {
        guard transition == nil else { return }
        setHover(hit(at: convert(event.locationInWindow, from: nil)), timestamp: event.timestamp)
    }

    private func refreshHoverFromMouse() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHover(bounds.contains(point) ? hit(at: point) : .none, timestamp: nil)
    }

    private func setHover(_ h: Hit, timestamp: TimeInterval?) {
        let newIndex: Int?
        if case .segment(let i) = h { newIndex = i } else { newIndex = nil }
        let newCentre = h == .centre && canGoUp
        if newCentre != centreHovered {
            centreHovered = newCentre
            needsDisplay = true
        }
        guard newIndex != hoverIndex else { return }
        hoverIndex = newIndex
        if let timestamp { pendingHoverTimestamp = timestamp }
        highlightChanged()
        onHover?(newIndex.flatMap { layout?.segments[$0] })
    }

    private func highlightChanged() {
        highlightSince = CACurrentMediaTime()
        if highlightedIndex != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            startLink()
        }
        needsDisplay = true
    }

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
    }

    private func invalidateCache() {
        cacheValid = false
        colorCache.removeAll()
        needsDisplay = true
    }

    private var appearanceKind: Appearance {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    private var highContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }

    private struct ColorKey: Hashable {
        let kind: SegmentKind
        let hue: Int
        let ring: Int
    }

    private func color(for s: Segment) -> CGColor {
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

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let layout, !bounds.isEmpty else { return }
        let drawStart = Timings.now
        let g = geometry
        let now = CACurrentMediaTime()

        if var t = transition {
            let raw = min(max((now - t.start) / t.duration, 0), 1)
            let e = CGFloat(raw < 0.5 ? 2 * raw * raw : 1 - pow(-2 * raw + 2, 2) / 2)   // ease-in-out
            drawTransition(t, progress: e, to: layout, in: ctx, geometry: g)
            t.frames += 1
            if t.frames > 1 { Timings.mark("frameInterval", (now - t.lastFrame) * 1000) }
            t.lastFrame = now
            transition = t
            Timings.mark("frame", (Timings.now - drawStart) * 1000)
        } else {
            if !cacheValid { renderCache(layout: layout, geometry: g) }
            if let cache {
                ctx.saveGState()
                ctx.translateBy(x: 0, y: bounds.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(cache, in: CGRect(origin: .zero, size: bounds.size))
                ctx.restoreGState()
            }
            drawOverlay(layout: layout, in: ctx, geometry: g, now: now)
        }

        if let ts = pendingHoverTimestamp {
            pendingHoverTimestamp = nil
            Timings.mark("hover", (Timings.now - ts) * 1000)
        }
        if !firstFrameDone {
            firstFrameDone = true
            onFirstFrame?()
        }
    }

    /// Renders the resting chart (segments, disc, labels) at backing scale.
    private func renderCache(layout: SunburstLayout, geometry g: Geometry) {
        cacheValid = true
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let width = Int((bounds.width * scale).rounded(.up)), height = Int((bounds.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            cache = nil
            return
        }
        // Same coordinates as the flipped view.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            drawDisc(in: ctx, geometry: g)
            drawSegments(layout.segments, in: ctx, geometry: g) { s in
                (Double(s.ring), s.startAngle, s.endAngle)
            }
            drawLabels(title: title, subtitle: subtitle, alpha: 1, geometry: g)
        }
        NSGraphicsContext.current = previous
        cache = ctx.makeImage()
    }

    private func drawOverlay(layout: SunburstLayout, in ctx: CGContext, geometry g: Geometry, now: TimeInterval) {
        let fade = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? 1 : CGFloat(min(max((now - highlightSince) / Self.highlightFade, 0), 1))
        if let i = highlightedIndex, i < layout.segments.count {
            let s = layout.segments[i]
            let path = CGMutablePath()
            addSegment(to: path, geometry: g, ringPosition: CGFloat(s.ring),
                       a0: s.startAngle, a1: s.endAngle, gap: gap)
            let dark = appearanceKind == .dark
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 1, alpha: (dark ? 0.28 : 0.45) * fade))
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent((dark ? 0.5 : 0.35) * fade).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
        }
        if centreHovered {
            ctx.setFillColor(NSColor.labelColor.withAlphaComponent(0.05).cgColor)
            ctx.fillEllipse(in: discRect(g))
        }
    }

    private func drawTransition(_ t: Transition, progress e: CGFloat, to new: SunburstLayout,
                                in ctx: CGContext, geometry g: Geometry) {
        drawDisc(in: ctx, geometry: g)
        ctx.saveGState()
        // Rings pushed outward during a zoom are clipped at the chart's edge.
        ctx.addEllipse(in: CGRect(x: g.center.x - g.outer, y: g.center.y - g.outer,
                                  width: 2 * g.outer, height: 2 * g.outer))
        ctx.clip()
        let ed = Double(e)
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * ed }
        switch t.kind {
        case .crossfade:
            ctx.setAlpha(1 - e)
            drawSegments(t.from.segments, in: ctx, geometry: g) { (Double($0.ring), $0.startAngle, $0.endAngle) }
            ctx.setAlpha(e)
            drawSegments(new.segments, in: ctx, geometry: g) { (Double($0.ring), $0.startAngle, $0.endAngle) }
        case .zoomIn(let ring, let a0, let a1):
            let k = (a1 - a0) / (2 * .pi)
            ctx.setAlpha(1 - e)
            drawSegments(t.from.segments, in: ctx, geometry: g) { (Double($0.ring), $0.startAngle, $0.endAngle) }
            ctx.setAlpha(1)
            drawSegments(new.segments, in: ctx, geometry: g) { s in
                (lerp(Double(s.ring + ring), Double(s.ring)),
                 lerp(a0 + s.startAngle * k, s.startAngle), lerp(a0 + s.endAngle * k, s.endAngle))
            }
        case .zoomOut(let ring, let a0, let a1):
            let k = (a1 - a0) / (2 * .pi)
            ctx.setAlpha(e)
            drawSegments(new.segments, in: ctx, geometry: g) { (Double($0.ring), $0.startAngle, $0.endAngle) }
            ctx.setAlpha(1 - e)
            drawSegments(t.from.segments, in: ctx, geometry: g) { s in
                (lerp(Double(s.ring), Double(s.ring + ring)),
                 lerp(s.startAngle, a0 + s.startAngle * k), lerp(s.endAngle, a0 + s.endAngle * k))
            }
        }
        ctx.restoreGState()
        drawLabels(title: t.fromTitle, subtitle: t.fromSubtitle, alpha: 1 - e, geometry: g)
        drawLabels(title: title, subtitle: subtitle, alpha: e, geometry: g)
    }

    private var gap: CGFloat { Palette.segmentGap(appearance: appearanceKind, highContrast: highContrast) }

    /// Fills (or, for mount points, outlines) `segments`, one path per colour.
    /// `place` gives each segment's (ring position, start, end), possibly mid-animation.
    private func drawSegments(_ segments: [Segment], in ctx: CGContext, geometry g: Geometry,
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
    private func addSegment(to path: CGMutablePath, geometry g: Geometry, ringPosition: CGFloat,
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

    private func discRect(_ g: Geometry) -> CGRect {
        CGRect(x: g.center.x - g.discRadius, y: g.center.y - g.discRadius,
               width: 2 * g.discRadius, height: 2 * g.discRadius)
    }

    private func drawDisc(in ctx: CGContext, geometry g: Geometry) {
        let dark = appearanceKind == .dark
        ctx.setFillColor(NSColor.labelColor.withAlphaComponent(dark ? 0.07 : 0.035).cgColor)
        ctx.fillEllipse(in: discRect(g))
    }

    /// Size (large, never truncated: the font shrinks to fit) over the name
    /// (small, truncated in the middle).
    private func drawLabels(title: String, subtitle: String, alpha: CGFloat, geometry g: Geometry) {
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
        } while titleWidth > width && titleSize > 9

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(alpha),
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
