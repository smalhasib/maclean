import AppKit
import MacleanCore
import MacleanKit
import QuartzCore
import SwiftUI

extension SunburstChartView {
    func startTransition(from old: SunburstLayout, to new: SunburstLayout,
                                 fromTitle: String, fromSubtitle: String, morph: Bool = false) {
        let kind: Transition.Kind
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            kind = .crossfade
        } else if morph, old.root == new.root {
            kind = .morph(Self.morphPlan(from: old, to: new))
        } else if let s = old.segments.first(where: { $0.node == new.root }) {
            kind = .zoomIn(ring: s.ring, a0: s.startAngle, a1: s.endAngle)
        } else if let s = new.segments.first(where: { $0.node == old.root }) {
            kind = .zoomOut(ring: s.ring, a0: s.startAngle, a1: s.endAngle)
        } else {
            kind = .crossfade
        }
        let duration: TimeInterval
        switch kind {
        case .crossfade: duration = Self.crossfadeDuration
        case .morph: duration = Self.morphDuration
        case .zoomIn, .zoomOut: duration = Self.animationDuration
        }
        transition = Transition(kind: kind, from: old, fromTitle: fromTitle, fromSubtitle: fromSubtitle,
                                start: CACurrentMediaTime(), duration: duration)
        startLink()
        needsDisplay = true
    }

    // MARK: Display link (navigation animation only)

    func startLink() {
        guard link == nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if let t = transition, now - t.start >= t.duration {
            finishTransition()
        }
        if transition == nil { stopLink() }
        needsDisplay = true
    }

    func finishTransition() {
        guard let t = transition else { return }
        if t.frames > 1 {
            let elapsed = t.lastFrame - t.start
            if elapsed > 0 { Timings.mark("drillFPS", Double(t.frames) / elapsed) }
        }
        transition = nil
        frameContext = nil
        refreshHoverFromMouse()
        // A keyboard drill keeps the focus visible on a segment of the new chart.
        if keyboardFocus, window?.firstResponder === self {
            DispatchQueue.main.async { [weak self] in self?.onNeedsKeyboardSelection?() }
        }
        updateFocusLayer()
    }

    func drawTransition(_ t: Transition, progress e: CGFloat, to new: SunburstLayout,
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
        case .morph(let plan):
            // Vanished segments shrink to zero width at their collapse angle.
            drawSegments(plan.vanished, in: ctx, geometry: g) { s in
                let c = plan.closing[MorphKey(s)] ?? s.startAngle
                return (Double(s.ring), lerp(s.startAngle, c), lerp(s.endAngle, c))
            }
            drawSegments(new.segments, in: ctx, geometry: g) { s in
                let from = plan.start[MorphKey(s)] ?? (s.startAngle, s.startAngle)
                return (Double(s.ring), lerp(from.a0, s.startAngle), lerp(from.a1, s.endAngle))
            }
        }
        ctx.restoreGState()
        drawLabels(title: t.fromTitle, subtitle: t.fromSubtitle, alpha: 1 - e, geometry: g)
        drawLabels(title: title, subtitle: subtitle, alpha: e, geometry: g)
    }
}

// MARK: Morph (collect / uncollect)

extension SunburstChartView {
    /// Identity of a segment across two layouts of one root: its node, or for
    /// a "smaller objects" segment, its parent.
    enum MorphKey: Hashable {
        case node(NodeID)
        case smaller(parent: NodeID)

        init(_ s: Segment) { self = s.node.map(MorphKey.node) ?? .smaller(parent: s.parent) }
    }

    struct MorphPlan {
        /// Starting angles of each new segment: its old angles if it was
        /// drawn before, else zero width where its slot opens.
        let start: [MorphKey: (a0: Double, a1: Double)]
        /// Old segments missing from the new layout, in drawing order.
        let vanished: [Segment]
        /// The angle each vanished segment shrinks to (where its slot closes).
        let closing: [MorphKey: Double]
    }

    /// Matches `old` and `new` (same root) by `MorphKey`. A segment that
    /// appears or vanishes opens or closes at the far edge of its previous
    /// matched sibling (else its parent's start), so neighbours slide without
    /// gaps; inside a parent that itself appears or vanishes it follows the
    /// parent.
    static func morphPlan(from old: SunburstLayout, to new: SunburstLayout) -> MorphPlan {
        var oldByKey: [MorphKey: Segment] = [:]
        var newByKey: [MorphKey: Segment] = [:]
        oldByKey.reserveCapacity(old.segments.count)
        newByKey.reserveCapacity(new.segments.count)
        for s in old.segments { oldByKey[MorphKey(s)] = s }
        for s in new.segments { newByKey[MorphKey(s)] = s }

        /// For each segment of `segments` absent from `other`: the angle, in
        /// `other`, where it opens or closes. Segments come in ring order, so
        /// parents are seen before their children.
        func pivots(_ segments: [Segment], other: [MorphKey: Segment], root: NodeID) -> [MorphKey: Double] {
            var pivot: [MorphKey: Double] = [:]
            var lastEnd: [NodeID: Double] = [:]   // parent → `other` end of its last matched child so far
            for s in segments {
                let key = MorphKey(s)
                if let match = other[key] {
                    lastEnd[s.parent] = match.endAngle
                } else if let end = lastEnd[s.parent] {
                    pivot[key] = end
                } else if s.parent == root {
                    pivot[key] = 0
                } else if let p = other[.node(s.parent)] {
                    pivot[key] = p.startAngle
                } else {
                    pivot[key] = pivot[.node(s.parent)] ?? s.startAngle
                }
            }
            return pivot
        }

        let closing = pivots(old.segments, other: newByKey, root: old.root)
        let opening = pivots(new.segments, other: oldByKey, root: new.root)
        var start: [MorphKey: (a0: Double, a1: Double)] = [:]
        start.reserveCapacity(new.segments.count)
        for s in new.segments {
            let key = MorphKey(s)
            if let o = oldByKey[key] {
                start[key] = (o.startAngle, o.endAngle)
            } else {
                let a = opening[key] ?? s.startAngle
                start[key] = (a, a)
            }
        }
        let vanished = old.segments.filter { closing[MorphKey($0)] != nil }
        return MorphPlan(start: start, vanished: vanished, closing: closing)
    }
}
