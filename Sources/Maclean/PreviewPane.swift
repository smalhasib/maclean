import AppKit
import MacleanKit
import Quartz
import QuickLookThumbnailing
import SwiftUI

/// The content of the previewed file, under the side list: images, video, audio, PDF, text, SVG and
/// whatever else Quick Look (and any Quick Look plug-in installed) can show. It follows the
/// file under the pointer or selected, and collapses to its header.
struct PreviewPane: View {
    let model: ResultViewModel
    @AppStorage("ShowPreviewPane") private var expanded = true
    // `State` used as a type: the `@State` macro's plugin ships only with Xcode.
    /// The file shown, set a moment after the pointer settles so sweeping over rows doesn't load each one.
    private let shown = State<URL?>(initialValue: nil)
    private let info = State<PreviewInfo?>(initialValue: nil)
    /// False once Quick Look has nothing but an icon for this type (an .mkv, say).
    private let previewable = State(initialValue: true)

    static let previewHeight: CGFloat = 190
    static let footerHeight: CGFloat = 76

    var body: some View {
        if let node = model.previewNode {
            let path = model.tree.path(of: node)
            VStack(alignment: .leading, spacing: 0) {
                Separator()
                header(name: model.name(of: node))
                if expanded {
                    QuickLookPreview(url: shown.wrappedValue)
                        .frame(height: Self.previewHeight)
                        .id(path)   // a fresh view per file: no leftover video or page
                    footer(info.wrappedValue, previewable: previewable.wrappedValue)
                }
            }
            .task(id: path) { await load(path) }
        }
    }

    private func header(name: String) -> some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .secondaryText()
                    .frame(width: 10)
                Text("Preview").font(.caption.weight(.medium)).secondaryText()
                Text(name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? "Hide preview" : "Show preview")
    }

    @ViewBuilder
    private func footer(_ info: PreviewInfo?, previewable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let info {
                Text("\(info.kind) · \(SizeText.string(info.size))")
                    .secondaryText()
                    .lineLimit(1)
                if let date = info.modified {
                    Text("Modified \(date.formatted(date: .abbreviated, time: .shortened))")
                        .secondaryText()
                        .lineLimit(1)
                }
            }
            if !previewable {
                Text("No preview for this type. Show it in Finder (⌥⌘R) to open it.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        // Fixed, so the list above doesn't jump between files with and without the note.
        .frame(maxWidth: .infinity, minHeight: Self.footerHeight, maxHeight: Self.footerHeight, alignment: .topLeading)
    }

    private func load(_ path: String) async {
        // A short settle: the pointer sweeps over many rows.
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        let details = PreviewInfo.read(path: path)
        info.wrappedValue = details
        guard details != nil else {
            shown.wrappedValue = nil
            previewable.wrappedValue = true
            return
        }
        let url = URL(fileURLWithPath: path)
        shown.wrappedValue = url
        let has = await Self.hasPreview(url)
        if !Task.isCancelled { previewable.wrappedValue = has }
    }

    /// Whether Quick Look can draw more than a generic icon for `url`.
    private static func hasPreview(_ url: URL) async -> Bool {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 96, height: 96), scale: 2,
                                                   representationTypes: [.lowQualityThumbnail, .thumbnail])
        return (try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)) != nil
    }
}

/// An embedded Quick Look view.
struct QuickLookPreview: NSViewRepresentable {
    let url: URL?

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false   // no video or audio starts by itself while browsing
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard (view.previewItem as? NSURL)?.path != url?.path else { return }
        view.previewItem = url as NSURL?
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()   // releases the Quick Look extension's resources
    }
}
