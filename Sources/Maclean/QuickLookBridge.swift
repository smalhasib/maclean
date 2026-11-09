import AppKit
import Quartz
import SwiftUI

/// Quick Look for the item under the pointer or the selection.
///
/// `QLPreviewPanel` looks for its controller in the key window's responder
/// chain, so every result window inserts a `ResultResponder` right after the
/// window (see `ResultWindowBridge`). The previewed URL is app-wide: there is
/// only one panel.
@MainActor enum QuickLookBridge {
    fileprivate static var url: URL?

    static var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    /// Space: shows the panel for `path`, or closes it when it's open.
    @discardableResult
    static func toggle(path: String) -> ActionResult {
        if isVisible {
            QLPreviewPanel.shared().orderOut(nil)
            return .ok
        }
        guard Actions.exists(path) else { return .missing }
        url = URL(fileURLWithPath: path)
        QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
        return .ok
    }

    /// Opens the panel for `path`, or points an open panel at it (the explicit Preview actions).
    @discardableResult
    static func show(path: String) -> ActionResult {
        guard Actions.exists(path) else { return .missing }
        url = URL(fileURLWithPath: path)
        if isVisible {
            QLPreviewPanel.shared().reloadData()
        } else {
            QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
        }
        return .ok
    }

    /// Follows the selection while the panel is open.
    static func follow(path: String) {
        guard isVisible, Actions.exists(path), url?.path != path else { return }
        url = URL(fileURLWithPath: path)
        QLPreviewPanel.shared().reloadData()
    }
}

/// Sits right after a result window in its responder chain: the Quick Look
/// panel's controller, and the handler of the list's keys (↑/↓, Page Up/Down,
/// Home/End, Return, Space) when no view before it took them.
final class ResultResponder: NSResponder, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    weak var model: ResultViewModel?
    weak var router: WindowRouter?
    /// The window whose chain this responder sits in.
    weak var hostWindow: NSWindow?

    /// Tab cycle (spec §6): toolbar controls → list → chart → toolbar, and
    /// Shift-Tab the reverse. The list holds focus whenever the chart (an
    /// AppKit first responder) doesn't and no toolbar control is focused; the
    /// toolbar's focus is `model.toolbarFocus`, drawn by `BreadcrumbBar`.
    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        let shift = event.modifierFlags.contains(.shift)
        let tab = Int(event.keyCode) == KeyCode.tab && mods.isEmpty
        if let model, model.toolbarFocus != nil, mods.isEmpty, handleToolbarKey(event, model: model, shift: shift) {
            return
        }
        if let model, ResultActions(model: model, router: router).handleKey(event, chart: false) { return }
        if tab, let model {
            if shift {
                // Shift-Tab from the list: the toolbar's last control.
                model.toolbarFocus = model.toolbarItem(after: nil, backwards: true)
            } else if let chart = hostWindow?.contentView.flatMap(Self.chart(in:)) {
                chart.window?.makeFirstResponder(chart)
            }
            return
        }
        super.keyDown(with: event)
    }

    /// Keys while a toolbar control has the focus: Tab / Shift-Tab step
    /// through the controls and on to the list / chart, ←/→ step within the
    /// toolbar, Return or Space activates, Escape returns to the list. Other
    /// keys go to the list, which takes the focus back.
    private func handleToolbarKey(_ event: NSEvent, model: ResultViewModel, shift: Bool) -> Bool {
        guard let item = model.toolbarFocus else { return false }
        switch Int(event.keyCode) {
        case KeyCode.tab:
            let next = model.toolbarItem(after: item, backwards: shift)
            model.toolbarFocus = next
            if next == nil, shift, let chart = hostWindow?.contentView.flatMap(Self.chart(in:)) {
                chart.window?.makeFirstResponder(chart)
            }
        case KeyCode.left, KeyCode.right:
            if let next = model.toolbarItem(after: item, backwards: Int(event.keyCode) == KeyCode.left) {
                model.toolbarFocus = next
            }
        case KeyCode.return, KeyCode.enter, KeyCode.space:
            guard !shift, model.isEnabled(item) else { return true }
            switch item {
            case .collector: model.collectorPanelOpen.toggle()
            case .back: model.back()
            case .forward: model.forward()
            case .disks:
                model.toolbarFocus = nil
                router?.backToDisks(from: model)
            case .crumb(let path): model.visit(path: path)
            }
        case KeyCode.escape:
            // Escape closes the collector panel first, keeping the focus on its circle.
            if item == .collector, model.collectorPanelOpen {
                model.collectorPanelOpen = false
            } else {
                model.toolbarFocus = nil
            }
        default:
            model.toolbarFocus = nil
            return false
        }
        return true
    }

    static func chart(in view: NSView) -> SunburstChartView? {
        if let chart = view as? SunburstChartView { return chart }
        for sub in view.subviews { if let chart = chart(in: sub) { return chart } }
        return nil
    }

    override nonisolated func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
            panel.reloadData()
        }
    }

    override nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            if panel.dataSource === self { panel.dataSource = nil }
            if panel.delegate === self { panel.delegate = nil }
        }
    }

    /// The panel is key while open: list/chart navigation keys go on to the
    /// result window, so the selection (and the preview) can move.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, Self.forwardedKeys.contains(Int(event.keyCode)) else { return false }
        // Delivered on the main thread; NSEvent just isn't marked Sendable.
        nonisolated(unsafe) let event = event!
        return MainActor.assumeIsolated {
            guard let window = NSApp.mainWindow, let responder = window.firstResponder else { return false }
            responder.keyDown(with: event)
            return true
        }
    }

    /// Arrows, Return, Page Up/Down, Home, End.
    private nonisolated static let forwardedKeys: Set<Int> = [123, 124, 125, 126, 36, 116, 121, 115, 119]

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { QuickLookBridge.url == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let url = MainActor.assumeIsolated { QuickLookBridge.url }
        return url.map { $0 as NSURL }
    }
}

/// The Quick Look panel's controller for a window that has no result (the Smart
/// Clean sheet): `SheetQuickLook` puts one in the window's responder chain.
final class SheetQuickLookResponder: NSResponder, QLPreviewPanelDataSource {
    override nonisolated func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.reloadData()
        }
    }

    override nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { if panel.dataSource === self { panel.dataSource = nil } }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { QuickLookBridge.url == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let url = MainActor.assumeIsolated { QuickLookBridge.url }
        return url.map { $0 as NSURL }
    }
}

/// An invisible view that makes Quick Look work from its window.
struct SheetQuickLook: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Host() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Host: NSView {
        private let responder = SheetQuickLookResponder()

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, responder.nextResponder == nil else { return }
            responder.nextResponder = window.nextResponder
            window.nextResponder = responder
        }
    }
}
