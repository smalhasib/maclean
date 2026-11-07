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
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    rows(target)
                }
                .padding(.vertical, 6)
            }
        }
        .font(.body)
    }

    // MARK: Header

    private func header(_ target: NodeID) -> some View {
        let tree = model.tree
        let name = model.name(of: target)
        let count = tree.children(of: target).count
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
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(SizeText.string(tree.size(of: target)))
                .font(.headline)
                .monospacedDigit()
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
        let kids = tree.children(of: target)
        let visible = model.visibleChildCount(of: target)
        let isFolder = tree.flags(of: target).contains(.directory)

        if isFolder && (kids.isEmpty || tree.size(of: target) == 0) {
            Text("Empty folder")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }

        ForEach(0 ..< visible, id: \.self) { i in
            row(kids[i], index: i, parent: target)
        }

        if visible < kids.count {
            let expanded = model.isExpanded(target)
            let tail = kids.count - visible
            let tailSize = max(tree.size(of: target) - (0 ..< visible).reduce(Int64(0)) { $0 + tree.size(of: kids[$1]) }, 0)
            SmallerObjectsRow(count: tail, size: tailSize, expanded: expanded,
                              color: color(.smallerObjects, top: 0, ring: 1)) {
                model.expandedTarget = model.expandedTarget == target ? nil : target
            }
            if expanded {
                let end = min(kids.count, visible + ResultViewModel.expandedRowLimit)
                ForEach(visible ..< end, id: \.self) { i in
                    row(kids[i], index: i, parent: target)
                }
                if end < kids.count {
                    Text("\((kids.count - end).formatted()) more items")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                }
            }
        }

        if target == tree.root, let space = model.volumeSpace {
            Divider().padding(.vertical, 6).padding(.horizontal, 16)
            SpaceRow(title: "free space", size: space.free)
            SpaceRow(title: "free + purgeable", size: space.freePurgeable)
        }
    }

    private func row(_ node: NodeID, index: Int, parent: NodeID) -> some View {
        let c = model.colorInputs(child: node, index: index, parent: parent)
        return ListRow(name: model.tree.name(of: node), size: model.tree.size(of: node),
                       color: color(c.kind, top: c.top, ring: c.ring), outlined: c.kind == .mountPoint,
                       drillable: model.isDrillable(node),
                       highlighted: model.hoverSource == .list && model.hovered == node,
                       selected: model.selected == node) { inside in
            if inside {
                model.hover(node, from: .list)
            } else if model.hoverSource == .list, model.hovered == node {
                model.hover(nil, from: .list)
            }
        } onTap: {
            if model.isDrillable(node) { model.open(node) } else { model.selected = node }
        }
    }

    // MARK: Colours

    private func headerColor(_ target: NodeID) -> Color {
        if let s = model.segment(for: target) { return color(s.kind, top: s.topLevelIndex, ring: s.ring) }
        if model.kind(of: target) == .folder { return Color(nsColor: .tertiaryLabelColor) }
        return color(model.kind(of: target), top: 0, ring: 1)
    }

    private func color(_ kind: SegmentKind, top: Int, ring: Int) -> Color {
        let rgb = Palette.color(kind: kind, topLevelIndex: top, ring: ring,
                                appearance: colorScheme == .dark ? .dark : .light,
                                highContrast: contrast == .increased)
        return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: kind == .smallerObjects ? 0.6 : 1)
    }
}

/// Dot, name (middle-truncated, full name in the tooltip) and size (never truncated).
private struct ListRow: View {
    let name: String
    let size: Int64
    let color: Color
    let outlined: Bool
    let drillable: Bool
    let highlighted: Bool
    let selected: Bool
    let onHover: (Bool) -> Void
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 10) {
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
                .help(name)
            Spacer(minLength: 8)
            Text(SizeText.string(size))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .opacity(drillable ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.18)
                      : highlighted ? Color.primary.opacity(0.06) : .clear)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 6)
        .onHover(perform: onHover)
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
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
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("\(count.formatted()) items")
            Spacer(minLength: 8)
            Text(SizeText.string(size))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

private struct SpaceRow: View {
    let title: String
    let size: Int64

    var body: some View {
        HStack(spacing: 10) {
            Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.5).frame(width: 9, height: 9)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(SizeText.string(size))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}
