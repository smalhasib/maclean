import AppKit
import MacleanCore
import MacleanKit
import SwiftUI

/// The list beside the chart: the list target (the chart-hovered item, else
/// the current folder) as a header, its children largest first, then
/// "smaller objects…", and at a volume root the free-space rows.
struct SideListView: View {
    let model: ResultViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let target = model.listTarget
        VStack(alignment: .leading, spacing: 0) {
            header(target)
            Separator()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        rows(target)
                    }
                    .padding(.vertical, 6)
                }
                // Keyboard selection stays in view (rows are identified by index).
                .onChange(of: model.selected) { _, _ in
                    if let row = model.selectedRow { proxy.scrollTo(row) }
                }
            }
        }
        .font(.body)
    }

    // MARK: Header

    private func header(_ target: NodeID) -> some View {
        let view = model.view
        let name = model.name(of: target)
        let count = view.children(of: target).count
        return HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(headerColor(target))
                .frame(width: 11, height: 11)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(name)
                Text(kindText(target, count: count))
                    .secondaryText()
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(SizeText.string(view.size(of: target)))
                .font(.headline)
                .monospacedDigit()
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(kindText(target, count: count)), \(SizeText.spoken(view.size(of: target)))")
        .accessibilityAddTraits(.isHeader)
    }

    private func kindText(_ node: NodeID, count: Int) -> String {
        switch model.kind(of: node) {
        case .file: return "File"
        case .package: return "Package"
        case .restricted: return "Can't be read"
        case .mountPoint: return "Another volume"
        case .folder, .smallerObjects: return count == 1 ? "1 item" : "\(count.formatted()) items"
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func rows(_ target: NodeID) -> some View {
        let tree = model.tree
        let view = model.view
        let kids = view.children(of: target)
        let visible = model.visibleChildCount(of: target)
        let isFolder = tree.flags(of: target).contains(.directory)

        if isFolder && (kids.isEmpty || view.size(of: target) == 0) {
            Text("Empty folder")
                .secondaryText()
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }

        RowBlock(model: model, target: target, range: 0 ..< visible)

        let tailSize = max(view.size(of: target) - (0 ..< visible).reduce(Int64(0)) { $0 + view.size(of: kids[$1]) }, 0)
        if visible < kids.count, tailSize > 0 {
            let expanded = model.isExpanded(target)
            SmallerObjectsRow(count: kids.count - visible, size: tailSize, expanded: expanded,
                              color: color(.smallerObjects, top: 0, ring: 1)) {
                model.expandedTarget = model.expandedTarget == target ? nil : target
            }
            if expanded {
                let end = min(kids.count, visible + ResultViewModel.expandedRowLimit)
                RowBlock(model: model, target: target, range: visible ..< end)
                if end < kids.count {
                    Text("\((kids.count - end).formatted()) more items")
                        .secondaryText()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                }
            }
        }

        if target == tree.root, let space = model.volumeSpace {
            Separator().padding(.vertical, 6).padding(.horizontal, 16)
            SpaceRow(title: "free space", size: space.free)
            SpaceRow(title: "free + purgeable", size: space.freePurgeable)
        }
    }

    // MARK: Colours

    private func headerColor(_ target: NodeID) -> Color {
        if let s = model.segment(for: target) { return color(s.kind, top: s.topLevelIndex, ring: s.ring) }
        if model.kind(of: target) == .folder { return Color(nsColor: .tertiaryLabelColor) }
        return color(model.kind(of: target), top: 0, ring: 1)
    }

    private func color(_ kind: SegmentKind, top: Int, ring: Int) -> Color {
        SideListView.color(kind, top: top, ring: ring, dark: colorScheme == .dark, highContrast: contrast == .increased)
    }

    static func color(_ kind: SegmentKind, top: Int, ring: Int, dark: Bool, highContrast: Bool) -> Color {
        let rgb = Palette.color(kind: kind, topLevelIndex: top, ring: ring,
                                appearance: dark ? .dark : .light, highContrast: highContrast)
        return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: kind == .smallerObjects ? 0.6 : 1)
    }
}

/// A run of child rows (`range` of `target`'s children) with fixed-height
/// rows, so one continuous-hover handler and one tap handler map the
/// pointer's y to a row instead of every row tracking the mouse itself.
private struct RowBlock: View {
    let model: ResultViewModel
    let target: NodeID
    let range: Range<Int>
    @Environment(\.windowRouter) private var router

    static let rowHeight: CGFloat = 30

    var body: some View {
        let kids = model.view.children(of: target)
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(range, id: \.self) { i in
                RowHost(model: model, node: kids[i], index: i, parent: target)
                    .frame(height: Self.rowHeight)
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point):
                if let node = node(at: point.y, kids: kids) {
                    model.hover(node, from: .list)
                } else {
                    clearHover(kids: kids)
                }
            case .ended:
                clearHover(kids: kids)
            }
        }
        .onTapGesture(coordinateSpace: .local) { point in
            guard let node = node(at: point.y, kids: kids) else { return }
            let flags = NSEvent.modifierFlags.intersection([.command, .option, .shift, .control])
            // Control-click opens the context menu; it never drills.
            if flags.contains(.control) { return }
            // Clicking the list gives it keyboard focus back from the chart (or toolbar).
            model.toolbarFocus = nil
            if let window = NSApp.keyWindow, window.firstResponder is SunburstChartView {
                window.makeFirstResponder(window.contentView)
            }
            // ⌘-click: Show in Finder; ⌥-click a folder: Open in New Window.
            if ResultActions(model: model, router: router).modifiedClick(node, flags: flags) { return }
            model.activate(node)
        }
    }

    private func node(at y: CGFloat, kids: ViewChildren) -> NodeID? {
        guard y >= 0 else { return nil }
        let i = range.lowerBound + Int(y / Self.rowHeight)
        return range.contains(i) && i < kids.count ? kids[i] : nil
    }

    /// Clears a list hover only if it belongs to this block (another block may own it now).
    private func clearHover(kids: ViewChildren) {
        guard model.hoverSource == .list, let hovered = model.hovered else { return }
        // Bounded by the block's row count (at most `expandedRowLimit`).
        if range.contains(where: { $0 < kids.count && kids[$0] == hovered }) { model.hover(nil, from: .list) }
    }
}

/// Reads the hover/selection state for one row, so the list body doesn't
/// depend on it; the row itself is `Equatable` and only redraws when its
/// inputs change.
private struct RowHost: View {
    let model: ResultViewModel
    let node: NodeID
    let index: Int
    let parent: NodeID
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let c = model.colorInputs(child: node, index: index, parent: parent)
        ListRow(name: model.tree.name(of: node), size: model.view.size(of: node),
                kind: ResultViewModel.kindWord(model.kind(of: node)),
                color: SideListView.color(c.kind, top: c.top, ring: c.ring, dark: colorScheme == .dark,
                                          highContrast: contrast == .increased),
                outlined: c.kind == .mountPoint, drillable: model.isDrillable(node),
                // `hovered` is only read for list hovers, so chart hovers don't invalidate rows.
                highlighted: model.hoverSource == .list && model.hovered == node,
                selected: model.selected == node)
            .equatable()
            // Drags carry only `org.maclean.node`, never a file URL.
            .onDrag { NodeDrag.provider(for: model.dragPayload(for: node)) }
            .contextMenu { ContextMenuContent(model: model, node: node) }
            .accessibilityAction { model.activate(node) }
    }
}

/// Dot, name (middle-truncated; the full name is the tooltip of the hovered
/// row) and size (never truncated).
private struct ListRow: View, Equatable {
    let name: String
    let size: Int64
    /// Spoken kind: "folder", "file" or "package".
    let kind: String
    let color: Color
    let outlined: Bool
    let drillable: Bool
    let highlighted: Bool
    let selected: Bool

    var body: some View {
        let row = HStack(spacing: 10) {
            Group {
                if outlined {
                    Circle().strokeBorder(color, lineWidth: 1.5)
                } else {
                    Circle().fill(color)
                }
            }
            .frame(width: 9, height: 9)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(SizeText.string(size))
                .secondaryText()
                .monospacedDigit()
                .fixedSize()
            Image(systemName: "chevron.right")
                .imageScale(.small)
                .foregroundStyle(.tertiary)
                .opacity(drillable ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.18)
                      : highlighted ? Color.primary.opacity(0.06) : .clear)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        // VoiceOver: "Users, folder, 307.6 gigabytes".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(kind), \(SizeText.spoken(size))")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)

        if highlighted { row.help(name) } else { row }
    }
}

private struct SmallerObjectsRow: View {
    let count: Int
    let size: Int64
    let expanded: Bool
    let color: Color
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text("smaller objects…")
                .secondaryText()
                .lineLimit(1)
                .help("\(count.formatted()) items")
            Spacer(minLength: 8)
            Text(SizeText.string(size))
                .secondaryText()
                .monospacedDigit()
                .fixedSize()
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .imageScale(.small)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("smaller objects, \(count.formatted()) items, \(SizeText.spoken(size))")
        .accessibilityValue(expanded ? "expanded" : "collapsed")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
    }
}

private struct SpaceRow: View {
    let title: String
    let size: Int64

    var body: some View {
        HStack(spacing: 10) {
            Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.5).frame(width: 9, height: 9)
            Text(title).secondaryText()
            Spacer(minLength: 8)
            Text(SizeText.string(size))
                .secondaryText()
                .monospacedDigit()
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(SizeText.spoken(size))")
    }
}

extension View {
    /// Secondary text; with Increase Contrast, full-contrast primary text.
    func secondaryText() -> some View { modifier(SecondaryText()) }
}

private struct SecondaryText: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.foregroundStyle(contrast == .increased ? HierarchicalShapeStyle.primary : .secondary)
    }
}

/// A hairline separator; with Increase Contrast, a thicker, stronger line
/// (spec §7). Horizontal unless `vertical`.
struct Separator: View {
    var vertical = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if contrast == .increased {
            Rectangle()
                .fill(Color.primary.opacity(0.55))
                .frame(width: vertical ? 2 : nil, height: vertical ? nil : 2)
                .accessibilityHidden(true)
        } else {
            Divider()
        }
    }
}
