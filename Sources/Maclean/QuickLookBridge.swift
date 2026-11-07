import AppKit
import Quartz

/// Quick Look for the item under the pointer or the selection.
///
/// `QLPreviewPanel` looks for its controller in the key window's responder
/// chain, so every result window inserts a `PreviewResponder` right after the
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

    /// Follows the selection while the panel is open.
    static func follow(path: String) {
        guard isVisible, Actions.exists(path), url?.path != path else { return }
        url = URL(fileURLWithPath: path)
        QLPreviewPanel.shared().reloadData()
    }
}

/// The panel's controller, inserted into a result window's responder chain.
final class PreviewResponder: NSResponder, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
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
