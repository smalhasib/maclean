import AppKit
import MacleanCore
import MacleanKit
import QuartzCore
import SwiftUI

extension SunburstChartView {
    func startTransition(from old: SunburstLayout, to new: SunburstLayout,
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
        }
        ctx.restoreGState()
        drawLabels(title: t.fromTitle, subtitle: t.fromSubtitle, alpha: 1 - e, geometry: g)
        drawLabels(title: title, subtitle: subtitle, alpha: e, geometry: g)
    }
}
