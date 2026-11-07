import AppKit
import MacleanCore
import MacleanKit
import QuartzCore
import SwiftUI

/// The ring chart for a result. Reads the model in `body`, so SwiftUI tracks
/// exactly the properties the chart depends on.
struct SunburstView: View {
    let model: ResultViewModel
    @Environment(\.windowRouter) private var router

    var body: some View {
        let node = model.currentNode
        // A list-row hover highlights its segment; otherwise the selection does.
        let external = model.hoverSource == .list ? (model.hovered ?? model.selected) : model.selected
        SunburstRepresentable(
            model: model, router: router, layout: model.layout, generation: model.layoutGeneration,
            title: SizeText.string(model.tree.size(of: node)), subtitle: model.name(of: node),
            canGoUp: model.tree.parent(of: node) != nil,
            listHoverIndex: external.flatMap { model.chartIndex(forListItem: $0) },
            selectedIndex: model.selected.flatMap { model.chartIndex(forListItem: $0) })
    }
}

/// `SunburstChartView` (Core Graphics in an NSView) wrapped for SwiftUI.
private struct SunburstRepresentable: NSViewRepresentable {
    let model: ResultViewModel
    let router: WindowRouter?
    let layout: SunburstLayout
    let generation: Int
    let title: String
    let subtitle: String
    let canGoUp: Bool
    let listHoverIndex: Int?
    /// The keyboard-current segment, outlined while the chart has keyboard focus.
    let selectedIndex: Int?

    func makeNSView(context: Context) -> SunburstChartView {
        let view = SunburstChartView()
        view.onHover = { [weak model] segment in
            model?.hover(segment?.node, from: .chart)
        }
        let router = self.router
        view.onClick = { [weak model] segment, flags in
            guard let model, let node = segment.node else { return }
            // ⌘-click: Show in Finder; ⌥-click a folder: Open in New Window.
            if ResultActions(model: model, router: router).modifiedClick(node, flags: flags) { return }
            if model.isDrillable(node) { model.open(node) } else { model.selected = node }
        }
        view.onMenu = { [weak model] segment in
            guard let model, let node = segment.node else { return nil }
            return ResultActions(model: model, router: router).contextMenu(for: node)
        }
        view.onPinch = { [weak model] opening in
            guard let model else { return }
            if opening {
                if let target = model.actionTarget { ResultActions(model: model, router: router).enter(target) }
            } else {
                model.goUp()
            }
        }
        view.onSwipe = { [weak model] back in
            if back { model?.back() } else { model?.forward() }
        }
        view.canSwipe = { [weak model] in (model?.history.canGoBack ?? false, model?.history.canGoForward ?? false) }
        view.onKey = { [weak model] event in
            guard let model else { return false }
            return ResultActions(model: model, router: router).handleKey(event, chart: true)
        }
        view.onCentreClick = { [weak model] in model?.goUp() }
        view.onFirstFrame = { [weak model] in model?.chartDidDrawFirstFrame() }
        // Tab cycle: chart → toolbar, Shift-Tab chart → list (the chart has
        // already handed first responder to the content view).
        view.onTabOut = { [weak model] backwards in
            guard let model else { return }
            model.toolbarFocus = backwards ? nil : model.toolbarItem(after: nil, backwards: false)
        }
        view.onFocus = { [weak model] in
            if model?.toolbarFocus != nil { model?.toolbarFocus = nil }
        }
        view.onNeedsKeyboardSelection = { [weak model] in model?.selectForKeyboardFocus() }
        view.segmentLabel = { [weak model] segment in
            guard let model else { return "" }
            guard let node = segment.node else { return "smaller objects, \(SizeText.spoken(segment.mergedSize))" }
            return model.accessibilityLabel(of: node)
        }
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
        view.setExternalHighlight(index: listHoverIndex)
        view.setSelectedIndex(selectedIndex)
    }
}
