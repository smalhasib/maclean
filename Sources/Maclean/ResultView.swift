import AppKit
import MacleanCore
import MacleanKit
import SwiftUI

/// A scan result: breadcrumbs on top, the ring chart and side list, and the
/// collector bar at the bottom.
///
/// Keyboard (spec §6) is handled in AppKit, so no SwiftUI focus wrapper sits
/// over the rows and chart (it would swallow their context menus): the chart
/// is its own first responder (arrow-key traversal), and every other key
/// reaches the window's `ResultResponder` (list selection, Return, Space).
/// The list "holds focus" whenever the chart doesn't; Tab toggles between them.
struct ResultView: View {
    let model: ResultViewModel
    let router: WindowRouter?
    let onDisks: () -> Void
    // `State` used as a type: the `@State` macro's plugin ships only with Xcode.
    private let grown = State(initialValue: false)

    static let minimumSize = CGSize(width: 760, height: 520)

    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbBar(model: model, onDisks: onDisks)
            Separator()
            ResultBanners(model: model)
            HStack(spacing: 0) {
                SunburstView(model: model)
                    .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
                Separator(vertical: true)
                SideListView(model: model)
                    .frame(width: 280)
            }
            Separator()
            CollectorBar()
        }
        // The minimum applies once the window has grown, so it animates
        // instead of snapping.
        .frame(minWidth: grown.wrappedValue ? Self.minimumSize.width : nil,
               minHeight: grown.wrappedValue ? Self.minimumSize.height : nil)
        .background(WindowGrower(minimum: Self.minimumSize) { grown.wrappedValue = true })
        .background(ResultWindowBridge(model: model, router: router, title: model.name(of: model.currentNode)))
        .environment(\.windowRouter, router)
        .onChange(of: model.selected) { _, node in
            // Quick Look follows the keyboard selection while it's open.
            if let node, model.hovered == nil { QuickLookBridge.follow(path: model.tree.path(of: node)) }
        }
    }
}

/// Inline banners under the toolbar: "… no longer exists" (dismissed after a
/// few seconds) and, in a window kept up during a rescan, its progress.
private struct ResultBanners: View {
    let model: ResultViewModel

    var body: some View {
        VStack(spacing: 0) {
            if model.session.isScanning {
                banner(icon: nil, text: model.session.isStopping ? "Stopping…" : "Rescanning…")
            } else if case .failed(let message) = model.session.state {
                banner(icon: "exclamationmark.triangle", text: "Rescan failed: \(message)")
            }
            if let notice = model.notice {
                banner(icon: "exclamationmark.triangle", text: notice.text) { model.dismissNotice() }
                    .task(id: notice.id) {
                        try? await Task.sleep(for: .seconds(4))
                        model.dismissNotice(notice.id)
                    }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: model.notice)
    }

    private func banner(icon: String?, text: String, dismiss: (() -> Void)? = nil) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon).secondaryText()
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(text)
                Spacer(minLength: 8)
                if let dismiss {
                    Button(action: dismiss) { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Dismiss")
                        .accessibilityLabel("Dismiss")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(Color.primary.opacity(0.04))
            Separator()
        }
        .accessibilityElement(children: .combine)
    }
}

/// Keeps a window's `ResultViewModel` across view re-evaluations, and
/// replaces it when a rescan brings a new tree: the new model keeps the old
/// one's folder, history and selection by path.
@MainActor final class ResultModelCache {
    private var model: ResultViewModel?
    /// Path a new window starts at (Open in New Window); nil starts where the session was.
    private let startPath: String?
    private let ownsSessionHistory: Bool

    init(startPath: String? = nil, ownsSessionHistory: Bool = true) {
        self.startPath = startPath
        self.ownsSessionHistory = ownsSessionHistory
    }

    /// The model for `session`'s current `tree`; with no tree (a rescan
    /// running or failed), the last model of that session.
    func model(for session: ScanSession, tree: FileTree?) -> ResultViewModel? {
        if let model, model.session === session, tree == nil || model.tree === tree { return model }
        guard let tree else { return nil }
        let new: ResultViewModel
        if let model, model.session === session {
            new = ResultViewModel(remapping: model, to: tree, ownsSessionHistory: ownsSessionHistory)
        } else if let startPath {
            new = ResultViewModel(session: session, startPath: startPath,
                                  history: NavigationHistory(rootPath: tree.rootPath), ownsSessionHistory: false)
        } else {
            new = ResultViewModel(session: session, ownsSessionHistory: ownsSessionHistory)
        }
        model = new
        return new
    }

    /// Releases the cached model (and its tree) if it belongs to `session`.
    func drop(session: ScanSession) {
        if model?.session === session { model = nil }
    }
}

/// Grows the hosting window (animated, top-left fixed) to at least `minimum`
/// when the result appears, then calls `done`.
private struct WindowGrower: NSViewRepresentable {
    let minimum: CGSize
    let done: () -> Void

    func makeNSView(context: Context) -> GrowerView {
        let view = GrowerView()
        view.minimum = minimum
        view.done = done
        return view
    }

    func updateNSView(_ view: GrowerView, context: Context) {}

    final class GrowerView: NSView {
        /// Invisible helper: never the target of clicks (it spans the whole
        /// result and would otherwise take right-clicks from SwiftUI's context menus).
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        var minimum: CGSize = .zero
        var done: (() -> Void)?
        private var grew = false

        /// Preferred size for a result, clamped to the screen.
        private static let preferred = CGSize(width: 980, height: 660)

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !grew, window != nil else { return }
            grew = true
            DispatchQueue.main.async { [weak self] in self?.grow() }
        }

        private func grow() {
            guard let window else { done?(); return }
            let content = window.contentRect(forFrameRect: window.frame).size
            let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
            let want = CGSize(width: max(content.width, Self.preferred.width),
                              height: max(content.height, Self.preferred.height))
            var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: want))
            frame.size.width = max(min(frame.width, visible.width), minimum.width)
            frame.size.height = max(min(frame.height, visible.height), minimum.height)
            frame.origin.x = window.frame.minX
            frame.origin.y = window.frame.maxY - frame.height
            if frame.maxX > visible.maxX { frame.origin.x = max(visible.minX, visible.maxX - frame.width) }
            if frame.minY < visible.minY { frame.origin.y = visible.minY }
            guard frame.size != window.frame.size else { done?(); return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                window.setFrame(frame, display: true)
                done?()
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.3
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    window.animator().setFrame(frame, display: true)
                } completionHandler: { [weak self] in
                    MainActor.assumeIsolated { self?.done?() }
                }
            }
        }
    }
}
