import AppKit

/// Action › "Delete Collected Items", added in AppKit after launch so it can
/// be validated (SwiftUI command enablement isn't re-evaluated reliably, see
/// `AppCommands`). It is enabled only when the front window's session has
/// collected items and isn't already deleting; choosing it starts the
/// delete countdown.
///
/// It goes right after "Remove All Items from Collector" (at the end of the
/// menu if that item isn't found), and is put back whenever SwiftUI rebuilds
/// the menu.
@MainActor final class DeleteMenuItem: NSObject, NSMenuItemValidation {
    static let title = "Delete Collected Items"
    private static let identifier = NSUserInterfaceItemIdentifier("maclean.deleteCollectedItems")
    private static let anchorTitle = "Remove All Items from Collector"

    private let router: WindowRouter
    private var observers: [any NSObjectProtocol] = []

    init(router: WindowRouter) {
        self.router = router
        super.init()
    }

    /// Inserts the item now and re-inserts it after menu changes.
    func install() {
        ensureInstalled()
        for name in [NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.ensureInstalled() }
            })
        }
    }

    private func ensureInstalled() {
        guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == "Action" })?.submenu,
              !menu.items.contains(where: { $0.identifier == Self.identifier }) else { return }
        let item = NSMenuItem(title: Self.title, action: #selector(deleteCollectedItems(_:)), keyEquivalent: "")
        item.identifier = Self.identifier
        item.target = self
        if let anchor = menu.items.firstIndex(where: { $0.title == Self.anchorTitle }) {
            menu.insertItem(item, at: anchor + 1)
        } else {
            menu.addItem(item)
        }
    }

    @objc private func deleteCollectedItems(_ sender: Any?) {
        guard let session = router.frontModel?.session else { return }
        session.deletion.requestDelete()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(deleteCollectedItems(_:)) else { return true }
        guard let session = router.frontModel?.session, let view = session.view else { return false }
        return !view.collected.isEmpty && !session.isDeleting
    }
}
