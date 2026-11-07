import AppKit
import MacleanCore
import SwiftUI

/// A scan result: breadcrumbs on top, the ring chart and side list, and the
/// collector bar at the bottom.
struct ResultView: View {
    let model: ResultViewModel
    let onDisks: () -> Void
    // `State` used as a type: the `@State` macro's plugin ships only with Xcode.
    private let grown = State(initialValue: false)

    static let minimumSize = CGSize(width: 760, height: 520)

    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbBar(model: model, onDisks: onDisks)
            Divider()
            HStack(spacing: 0) {
                SunburstView(model: model)
                    .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Ring chart")
                Divider()
                SideListView(model: model)
                    .frame(width: 280)
            }
            Divider()
            CollectorBar()
        }
        // The minimum applies once the window has grown, so it animates
        // instead of snapping.
        .frame(minWidth: grown.wrappedValue ? Self.minimumSize.width : nil,
               minHeight: grown.wrappedValue ? Self.minimumSize.height : nil)
        .background(WindowGrower(minimum: Self.minimumSize) { grown.wrappedValue = true })
    }
}

/// Keeps one `ResultViewModel` per presented result (session + tree), so
/// view re-evaluations don't rebuild it.
@MainActor final class ResultModelCache {
    private var model: ResultViewModel?
    private var tree: FileTree?

    func model(for session: ScanSession, tree: FileTree) -> ResultViewModel {
        if let model, model.session === session, self.tree === tree { return model }
        let model = ResultViewModel(session: session)
        self.model = model
        self.tree = tree
        return model
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
