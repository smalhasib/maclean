import SwiftUI

/// Where each guided place is, collected from the result window's views.
struct GuideRegionKey: PreferenceKey {
    static let defaultValue: [GraphGuide.Focus: Anchor<CGRect>] = [:]
    static func reduce(value: inout [GraphGuide.Focus: Anchor<CGRect>],
                       nextValue: () -> [GraphGuide.Focus: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Marks this view as a place the graph guide can spotlight.
    func guideRegion(_ focus: GraphGuide.Focus) -> some View {
        anchorPreference(key: GuideRegionKey.self, value: .bounds) { [focus: $0] }
    }
}

/// The graph guide: the window dimmed except for the place a step is about, with a card
/// beside it. Covers the whole result, so nothing underneath can be clicked until it's done.
struct GuideOverlay: View {
    let model: ResultViewModel
    let regions: [GraphGuide.Focus: Anchor<CGRect>]

    private static let cardSize = CGSize(width: 300, height: 190)

    var body: some View {
        GeometryReader { proxy in
            if let index = model.guideStep, index < GraphGuide.steps.count {
                let step = GraphGuide.steps[index]
                let holes = spotlight(for: step.focus, in: proxy)
                let bounds = CGRect(origin: .zero, size: proxy.size)
                ZStack(alignment: .topLeading) {
                    // Takes every click, so the guide can't be bypassed by accident.
                    Color.clear.contentShape(Rectangle())
                    Canvas { context, _ in
                        var scrim = Path(bounds)
                        for hole in holes { scrim.addPath(hole) }
                        context.fill(scrim, with: .color(.black.opacity(0.62)), style: FillStyle(eoFill: true))
                        for hole in holes {
                            context.stroke(hole, with: .color(.white.opacity(0.85)), lineWidth: 2)
                        }
                    }
                    .allowsHitTesting(false)
                    card(step: step, index: index)
                        .frame(width: Self.cardSize.width, height: Self.cardSize.height)
                        .offset(cardOrigin(near: placementRect(for: step.focus, holes: holes, in: proxy), in: proxy.size))
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.guideStep)
    }

    // MARK: Spotlight

    /// The shapes left bright. A ring is its outer circle plus the disc inside it: even-odd
    /// filling the scrim over both leaves exactly the ring clear.
    private func spotlight(for focus: GraphGuide.Focus, in proxy: GeometryProxy) -> [Path] {
        func rect(_ key: GraphGuide.Focus, inset: CGFloat = 4) -> CGRect? {
            regions[key].map { proxy[$0].insetBy(dx: -inset, dy: -inset) }
        }
        func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
        switch focus {
        case .chart, .ring, .centre:
            guard let chart = rect(.chart, inset: 0) else { return [] }
            let g = GraphGuide.chartGeometry(in: chart)
            switch focus {
            case .chart: return [circle(g.center, g.outer + 8)]
            case .ring: return [circle(g.center, g.outer + 2), circle(g.center, g.inner)]
            default: return [circle(g.center, g.disc + 4)]
            }
        case .breadcrumbs, .list, .collector:
            guard let area = rect(focus) else { return [] }
            return [Path(roundedRect: area, cornerRadius: 8)]
        }
    }

    /// What the card keeps clear of: the spotlight, except for the centre, where it's the whole
    /// chart (a card beside just the centre disc would sit on the rings).
    private func placementRect(for focus: GraphGuide.Focus, holes: [Path], in proxy: GeometryProxy) -> CGRect {
        if focus == .centre, let anchor = regions[.chart] {
            let g = GraphGuide.chartGeometry(in: proxy[anchor])
            return CGRect(x: g.center.x - g.outer, y: g.center.y - g.outer, width: g.outer * 2, height: g.outer * 2)
        }
        return holes.first?.boundingRect ?? CGRect(origin: .zero, size: proxy.size)
    }

    /// Beside the spotlight when there's room (right, left, below, then above), kept inside the window.
    private func cardOrigin(near spot: CGRect, in size: CGSize) -> CGSize {
        let w = Self.cardSize.width, h = Self.cardSize.height, gap: CGFloat = 16, edge: CGFloat = 12
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), max(lo, hi)) }
        let y = clamp(spot.midY - h / 2, edge, size.height - h - edge)
        let x = clamp(spot.midX - w / 2, edge, size.width - w - edge)
        if spot.maxX + gap + w <= size.width - edge { return CGSize(width: spot.maxX + gap, height: y) }
        if spot.minX - gap - w >= edge { return CGSize(width: spot.minX - gap - w, height: y) }
        if spot.maxY + gap + h <= size.height - edge { return CGSize(width: x, height: spot.maxY + gap) }
        if spot.minY - gap - h >= edge { return CGSize(width: x, height: spot.minY - gap - h) }
        return CGSize(width: x, height: y)
    }

    // MARK: Card

    private func card(step: GraphGuide.Step, index: Int) -> some View {
        let last = index == GraphGuide.steps.count - 1
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                ForEach(0..<GraphGuide.steps.count, id: \.self) { i in
                    Circle()
                        .fill(i == index ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: 6, height: 6)
                }
                Spacer()
                Text("\(index + 1) of \(GraphGuide.steps.count)").font(.caption).secondaryText()
            }
            Text(step.title).font(.headline)
            Text(step.body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Button("Skip") { model.endGuide() }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if index > 0 {
                    Button("Back") { model.guideBack() }
                }
                Button(last ? "Done" : "Next") { model.guideNext() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Graph guide, step \(index + 1) of \(GraphGuide.steps.count): \(step.title)")
    }
}
