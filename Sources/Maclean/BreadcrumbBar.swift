import SwiftUI

/// Toolbar row: back/forward, then **Disks** › root › … › current folder.
/// Middle crumbs collapse into "…" (a menu of the hidden ones) when space is tight.
struct BreadcrumbBar: View {
    let model: ResultViewModel
    let onDisks: () -> Void

    private struct Crumb: Identifiable {
        let name: String
        let path: String
        var id: String { path }
    }

    private var crumbs: [Crumb] { model.crumbs.map { Crumb(name: $0.name, path: $0.path) } }

    @Environment(\.controlActiveState) private var activeState

    /// Whether `item` shows the keyboard focus (in the key window only).
    private func focused(_ item: ResultViewModel.ToolbarItem) -> Bool {
        model.toolbarFocus == item && activeState == .key
    }

    /// A mouse click on a control moves the keyboard focus off the toolbar.
    private func click(_ action: () -> Void) {
        model.toolbarFocus = nil
        action()
    }

    var body: some View {
        HStack(spacing: 6) {
            Button { click(model.back) } label: {
                Image(systemName: "chevron.left").frame(width: 22, height: 22)
            }
            .focusOutline(focused(.back))
            .disabled(!model.history.canGoBack)
            .help("Back")
            .accessibilityLabel("Back")
            Button { click(model.forward) } label: {
                Image(systemName: "chevron.right").frame(width: 22, height: 22)
            }
            .focusOutline(focused(.forward))
            .disabled(!model.history.canGoForward)
            .help("Forward")
            .accessibilityLabel("Forward")

            let all = crumbs
            ViewThatFits(in: .horizontal) {
                trail(all, keepLast: all.count)
                ForEach([3, 2, 1].filter { $0 < all.count - 1 }, id: \.self) { keep in
                    trail(all, keepLast: keep)
                }
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    /// Disks, the root crumb, "…" for hidden middle crumbs, then the last `keepLast`.
    private func trail(_ all: [Crumb], keepLast: Int) -> some View {
        let hidden = keepLast >= all.count - 1 ? [] : Array(all[1 ..< all.count - keepLast])
        let shown = hidden.isEmpty ? all : [all[0]] + Array(all.suffix(keepLast))
        return HStack(spacing: 4) {
            Button("Disks") { click(onDisks) }
                .fixedSize()
                .focusOutline(focused(.disks))
            ForEach(Array(shown.enumerated()), id: \.element.id) { offset, crumb in
                separator
                if offset == 1, !hidden.isEmpty {
                    Menu {
                        ForEach(hidden) { c in
                            Button(c.name) { click { model.visit(path: c.path) } }
                        }
                    } label: {
                        Text("…")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    // A focused crumb that is collapsed shows its focus here.
                    .focusOutline(hidden.contains { focused(.crumb($0.path)) })
                    .accessibilityLabel("Hidden folders")
                    separator
                }
                crumbButton(crumb, isLast: offset == shown.count - 1)
            }
        }
    }

    /// Drawn as a shape: an SF Symbol next to right-to-left crumb text can render mirrored.
    private var separator: some View {
        CrumbChevron()
            .stroke(.tertiary, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            .frame(width: 5, height: 10)
            .padding(.horizontal, 3)
            .accessibilityHidden(true)
    }

    private func crumbButton(_ crumb: Crumb, isLast: Bool) -> some View {
        Button { click { model.visit(path: crumb.path) } } label: {
            Text(crumb.name)
                .fontWeight(isLast ? .semibold : .regular)
                .foregroundStyle(isLast ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: isLast ? 260 : 160, alignment: .leading)
                .fixedSize()   // natural width, capped (and middle-truncated) at the max
        }
        .focusOutline(focused(.crumb(crumb.path)))
        .help(crumb.name)
        .layoutPriority(isLast ? 1 : 0)
    }
}

private struct CrumbChevron: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return path
    }
}

extension View {
    /// The keyboard-focus outline of a toolbar control (Tab cycle; see `ResultResponder`).
    func focusOutline(_ shown: Bool) -> some View {
        overlay {
            if shown {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(-3)
                    .allowsHitTesting(false)
            }
        }
    }
}
