import AppKit
import MacleanCore
import MacleanKit
import SwiftUI

/// The collector's items, in a panel that slides up over the chart from the
/// collector bar (up to `maxHeight`). Rows: icon, name, parent folder, size
/// and an × button; a context menu; draggable back onto the chart. Escape
/// closes it (`ResultActions.handleKey`).
struct CollectorPanel: View {
    let model: ResultViewModel
    let maxHeight: CGFloat

    static let rowHeight: CGFloat = 44

    var body: some View {
        let view = model.view
        let tree = view.tree
        let items = view.collected.sorted { tree.size(of: $0) > tree.size(of: $1) }
        let height = min(CGFloat(items.count) * Self.rowHeight + 12, max(maxHeight, Self.rowHeight + 12))
        VStack(spacing: 0) {
            Separator()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items, id: \.self) { node in
                        CollectorRow(model: model, node: node)
                            .frame(height: Self.rowHeight)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(height: height)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // While the pointer is over the panel, chart hovers underneath are ignored.
        .onHover { model.pointerInPanel = $0 }
        .shadow(color: .black.opacity(0.12), radius: 8, y: -2)
        // Dropping a row on its own panel does nothing (the chart behind would put it back).
        .onDrop(of: [.macleanNode], delegate: RejectDropDelegate())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Collected items")
    }
}

private struct RejectDropDelegate: DropDelegate {
    func validateDrop(info: DropInfo) -> Bool { false }
    func performDrop(info: DropInfo) -> Bool { false }
}

private struct CollectorRow: View {
    let model: ResultViewModel
    let node: NodeID
    @Environment(\.windowRouter) private var router

    var body: some View {
        let tree = model.tree
        let name = model.name(of: node)
        let path = tree.path(of: node)
        let parent = ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        let size = tree.size(of: node)
        let hovered = model.panelHovered == node
        HStack(spacing: 10) {
            Image(nsImage: FileIcons.icon(for: path))
                .resizable()
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(name)
                Text(parent)
                    .secondaryText()
                    .lineLimit(1)
                    // The tail of the parent path is the informative part.
                    .truncationMode(.head)
                    .help(parent)
            }
            Spacer(minLength: 8)
            Text(SizeText.string(size))
                .secondaryText()
                .monospacedDigit()
                .fixedSize()
            Button { model.session.uncollect([node]) } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove from Collector")
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(hovered ? Color.primary.opacity(0.06) : .clear)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                model.panelHovered = node
            } else if model.panelHovered == node {
                model.panelHovered = nil
            }
        }
        .onDrag { NodeDrag.provider(for: model.dragPayload(for: node)) }
        .contextMenu {
            ContextMenuButtons(items: ResultActions(model: model, router: router).collectorItems(for: node))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(SizeText.spoken(size))")
        .accessibilityAction(named: "Remove from Collector") { model.session.uncollect([node]) }
    }
}

/// Finder icons by path, cached (rows re-evaluate on every hover change).
@MainActor enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        if let icon = cache[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        if cache.count > 500 { cache.removeAll() }
        cache[path] = icon
        return icon
    }
}
