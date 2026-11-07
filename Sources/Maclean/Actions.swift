import AppKit
import MacleanCore
import MacleanKit
import SwiftUI

/// Outcome of an action on a path: `.missing` when the path no longer exists
/// (the UI shows an inline "No longer exists" message).
enum ActionResult: Equatable { case ok, missing }

/// Actions on files and folders that hand off to other apps.
@MainActor enum Actions {
    /// Reveals `path` in a Finder window, selected.
    static func showInFinder(_ path: String) -> ActionResult {
        guard exists(path) else { return .missing }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        return .ok
    }

    /// Opens the folder (for a file, its enclosing folder) in Terminal.app,
    /// as `open -a Terminal <folder>` does.
    static func openInTerminal(_ path: String) -> ActionResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return .missing }
        let folder = isDirectory.boolValue ? path : (path as NSString).deletingLastPathComponent
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            return .ok
        }
        NSWorkspace.shared.open([URL(fileURLWithPath: folder, isDirectory: true)], withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration())
        return .ok
    }

    /// Opens Finder's Get Info window for `path`: `osascript` sends Finder an
    /// Apple Event, off the main thread, with the path passed in argv (no
    /// escaping). macOS asks once for the Automation permission; if it was
    /// denied, `onDenied` runs on the main actor.
    static func getInfo(_ path: String, onDenied: (@MainActor () -> Void)? = nil) -> ActionResult {
        guard exists(path) else { return .missing }
        Task.detached(priority: .userInitiated) {
            let denied = runGetInfoScript(path)
            if denied, let onDenied { await MainActor.run { onDenied() } }
        }
        return .ok
    }

    /// Message shown when the Automation permission for Finder is denied.
    static let finderPermissionMessage = "Maclean needs permission to control Finder for Get Info"

    /// Runs the Get Info script; returns true when Automation was denied (-1743).
    private nonisolated static func runGetInfoScript(_ path: String) -> Bool {
        let lines = [
            "on run argv",
            "tell application \"Finder\"",
            "activate",
            "open information window of (POSIX file (item 1 of argv) as alias)",
            "end tell",
            "end run",
        ]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = lines.flatMap { ["-e", $0] } + [path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("Maclean: Get Info failed to start osascript: %@", String(describing: error))
            return false
        }
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return false }
        NSLog("Maclean: Get Info failed: %@", message)
        return message.contains("-1743") || message.localizedCaseInsensitiveContains("not authorized")
    }

    static func launchDiskUtility() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.DiskUtility") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
}

/// Virtual key codes of the keys the result window handles itself.
enum KeyCode {
    static let `return` = 36, enter = 76, space = 49, tab = 48, escape = 53
    static let left = 123, right = 124, down = 125, up = 126
    static let pageUp = 116, pageDown = 121, home = 115, end = 119
}

/// One item of an item's context menu, rendered by SwiftUI (list rows) and
/// AppKit (chart segments) from the same list.
struct ContextItem {
    enum Shortcut { case space, command(Character, NSEvent.ModifierFlags) }
    let title: String
    var shortcut: Shortcut?
    var separatorBefore = false
    let action: @MainActor () -> Void
}

/// The actions a result window offers on its items (context menu, keyboard,
/// ⌘-/⌥-click, menu bar), reporting vanished paths on the model.
@MainActor struct ResultActions {
    let model: ResultViewModel
    let router: WindowRouter?

    private var tree: FileTree { model.tree }

    /// Return / ⌘↓ / pinch-open: enters a folder, or a package (Show Package Contents).
    func enter(_ node: NodeID) {
        let kind = model.kind(of: node)
        if kind == .folder || kind == .package { model.open(node) }
    }

    func preview(_ node: NodeID) {
        let path = tree.path(of: node)
        if QuickLookBridge.toggle(path: path) == .missing { model.reportMissing(node) }
    }

    func showInFinder(_ node: NodeID) {
        if Actions.showInFinder(tree.path(of: node)) == .missing { model.reportMissing(node) }
    }

    func openInTerminal(_ node: NodeID) {
        if Actions.openInTerminal(tree.path(of: node)) == .missing { model.reportMissing(node) }
    }

    /// Opens a folder in its own window (reusing this tree), in either window mode.
    func openInNewWindow(_ node: NodeID) {
        guard canOpenInNewWindow(node) else { return }
        router?.show(session: model.session, at: tree.path(of: node), forceNewWindow: true)
    }

    func canOpenInNewWindow(_ node: NodeID) -> Bool { model.kind(of: node) == .folder }

    func isStarred(_ node: NodeID) -> Bool {
        let path = tree.path(of: node)
        return router?.startModel.starred.contains { $0.path == path } ?? false
    }

    func toggleStar(_ node: NodeID) {
        guard let start = router?.startModel else { return }
        let path = tree.path(of: node)
        if isStarred(node) {
            start.unstar(path)
        } else if Actions.exists(path) {
            start.star(URL(fileURLWithPath: path, isDirectory: true))
        } else {
            model.reportMissing(node)
        }
    }

    /// A click with modifiers: ⌘ shows in Finder, ⌥ opens a folder in a new
    /// window. Returns false when the click is a plain one.
    func modifiedClick(_ node: NodeID, flags: NSEvent.ModifierFlags) -> Bool {
        if flags.contains(.command) { showInFinder(node); return true }
        if flags.contains(.option), canOpenInNewWindow(node) { openInNewWindow(node); return true }
        return false
    }

    /// Keys not taken by the menu bar (spec §6), for the list (`chart` false)
    /// or the chart. Returns false for keys it doesn't handle.
    func handleKey(_ event: NSEvent, chart: Bool) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods.isEmpty else { return false }
        switch Int(event.keyCode) {
        case KeyCode.return, KeyCode.enter:
            if let target = model.actionTarget { enter(target) }
        case KeyCode.space:
            if let target = model.actionTarget { preview(target) }
        case KeyCode.left where chart: model.traverse(.previous)
        case KeyCode.right where chart: model.traverse(.next)
        case KeyCode.up: if chart { model.traverse(.out) } else { model.moveSelection(.up) }
        case KeyCode.down: if chart { model.traverse(.into) } else { model.moveSelection(.down) }
        case KeyCode.pageUp where !chart: model.moveSelection(.pageUp)
        case KeyCode.pageDown where !chart: model.moveSelection(.pageDown)
        case KeyCode.home where !chart: model.moveSelection(.home)
        case KeyCode.end where !chart: model.moveSelection(.end)
        default: return false
        }
        return true
    }

    /// Context menu of an item (spec §5.3).
    func contextItems(for node: NodeID) -> [ContextItem] {
        let kind = model.kind(of: node)
        let name = model.name(of: node)
        var items: [ContextItem] = []
        if kind == .folder {
            items.append(ContextItem(title: "Expand “\(name)”") { enter(node) })
        }
        if kind == .package {
            items.append(ContextItem(title: "Show Package Contents") { enter(node) })
        }
        items.append(ContextItem(title: "Preview", shortcut: .space, separatorBefore: !items.isEmpty) {
            preview(node)
        })
        items.append(ContextItem(title: "Show in Finder", shortcut: .command("r", [.command, .option])) {
            showInFinder(node)
        })
        items.append(ContextItem(title: "Open in Terminal", shortcut: .command("t", [.command, .option])) {
            openInTerminal(node)
        })
        if canOpenInNewWindow(node) {
            items.append(ContextItem(title: "Open in New Window", shortcut: .command("n", [.command, .shift]),
                                     separatorBefore: true) { openInNewWindow(node) })
        }
        if kind == .folder {
            items.append(ContextItem(title: isStarred(node) ? "Unstar Folder" : "Star Folder",
                                     separatorBefore: !canOpenInNewWindow(node)) { toggleStar(node) })
        }
        return items
    }

    /// The context menu as an AppKit menu (chart segments).
    func contextMenu(for node: NodeID) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in contextItems(for: node) {
            if item.separatorBefore { menu.addItem(.separator()) }
            let menuItem = ClosureMenuItem(title: item.title, action: item.action)
            switch item.shortcut {
            case .space:
                menuItem.keyEquivalent = " "
                menuItem.keyEquivalentModifierMask = []
            case .command(let key, let flags):
                menuItem.keyEquivalent = String(key)
                menuItem.keyEquivalentModifierMask = flags
            case nil:
                break
            }
            menu.addItem(menuItem)
        }
        return menu
    }
}

/// The context menu as SwiftUI buttons (list rows). Built only when the
/// menu's content is evaluated, not on every row update.
struct ContextMenuContent: View {
    let model: ResultViewModel
    let node: NodeID
    @Environment(\.windowRouter) private var router

    var body: some View {
        let items = ResultActions(model: model, router: router).contextItems(for: node)
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            if item.separatorBefore { Divider() }
            button(item)
        }
    }

    @ViewBuilder
    private func button(_ item: ContextItem) -> some View {
        let button = Button(item.title) { item.action() }
        switch item.shortcut {
        case .space:
            button.keyboardShortcut(.space, modifiers: [])
        case .command(let key, let flags):
            button.keyboardShortcut(KeyEquivalent(key), modifiers: EventModifiers(flags))
        case nil:
            button
        }
    }
}

extension EventModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var m: EventModifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.control) { m.insert(.control) }
        self = m
    }
}

/// An `NSMenuItem` that runs a closure.
@MainActor final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, action handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}

private struct WindowRouterKey: EnvironmentKey {
    static let defaultValue: WindowRouter? = nil
}

extension EnvironmentValues {
    /// The app's window router, for views that open windows or reach the start model.
    var windowRouter: WindowRouter? {
        get { self[WindowRouterKey.self] }
        set { self[WindowRouterKey.self] = newValue }
    }
}
