import AppKit
import MacleanCore
import SwiftUI

/// Where Help points. nil until the project's repository exists; the Help
/// items are hidden until then.
enum ProjectLinks {
    static let repository: URL? = nil
    static var help: URL? { repository?.appending(path: "blob/main/README.md") }
    static var issues: URL? { repository?.appending(path: "issues/new") }
}

/// The menu bar (spec §6, plus R14's Enter Folder, Preview and Open in New
/// Window so every action is in it). App, Edit, View (Enter Full Screen) and
/// Window (with tabbing) are the standard ones; File, Go, Action and Help are
/// built here.
///
/// Items act on the result in the front window, looked up when the item is
/// chosen (`WindowRouter.frontModel`), and on the item under the pointer or
/// the selection where that applies (spec §5.3). They stay enabled and do
/// nothing without a result: SwiftUI doesn't reliably re-evaluate command
/// enablement when the front window or its history changes, and a stale
/// disabled item would swallow its shortcut.
struct AppCommands: Commands {
    let registry: SessionRegistry
    let router: WindowRouter

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Scan Folder…") { FolderPicker.scan(into: registry) }
                .keyboardShortcut("o")
            Button("Open in New Window") {
                guard let model = router.frontModel else { return }
                ResultActions(model: model, router: router).openInNewWindow(model.actionTarget ?? model.currentNode)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w")
        }
        CommandMenu("Go") {
            GoMenu(router: router)
        }
        CommandMenu("Action") {
            ActionMenu(router: router)
        }
        CommandGroup(replacing: .help) {
            if let help = ProjectLinks.help, let issues = ProjectLinks.issues {
                Button("Maclean Help") { NSWorkspace.shared.open(help) }
                Button("Report an Issue") { NSWorkspace.shared.open(issues) }
            }
        }
    }
}

private struct GoMenu: View {
    let router: WindowRouter
    @AppStorage(ResultViewModel.alwaysExpandKey) private var alwaysExpand = false

    var body: some View {
        Button("Back") { router.frontModel?.back() }
            .keyboardShortcut("[")
        Button("Forward") { router.frontModel?.forward() }
            .keyboardShortcut("]")
        Button("Enter Folder") {
            guard let model = router.frontModel, let target = model.actionTarget else { return }
            ResultActions(model: model, router: router).enter(target)
        }
        .keyboardShortcut(.downArrow, modifiers: .command)
        Button("Enclosing Folder") { router.frontModel?.goUp() }
            .keyboardShortcut(.upArrow, modifiers: .command)
        Button("Back to Disks") { if let model = router.frontModel { router.backToDisks(from: model) } }
            .keyboardShortcut("d", modifiers: [.command, .shift])
        Divider()
        Button("Expand “smaller objects”") { router.frontModel?.toggleSmallerObjects() }
            .keyboardShortcut("e")
        Toggle("Always Expand “smaller objects”", isOn: Binding(
            get: { alwaysExpand },
            set: { router.setAlwaysExpand($0) }))
    }
}

private struct ActionMenu: View {
    let router: WindowRouter

    var body: some View {
        Button("Rescan Current Folder") { if let model = router.frontModel { router.rescan(model) } }
            .keyboardShortcut("r")
        Button("Rescan") { if let model = router.frontModel { router.rescanDisk(model) } }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        Divider()
        // Space stays a view key (a plain-key menu equivalent would fire in
        // every window and text field); the title shows it instead.
        Button("Preview (Space)") { act { $0.preview($1) } }
        Button("Show in Finder") { act { $0.showInFinder($1) } }
            .keyboardShortcut("r", modifiers: [.command, .option])
        Button("Open in Terminal") { act { $0.openInTerminal($1) } }
            .keyboardShortcut("t", modifiers: [.command, .option])
        Button("Show Current Folder in Finder") { actOnFolder { $0.showInFinder($1) } }
        Button("Open Current Folder in Terminal") { actOnFolder { $0.openInTerminal($1) } }
        Divider()
        Button("Launch Disk Utility…") { Actions.launchDiskUtility() }
    }

    /// Runs `action` on the item under the pointer or the selection, else the current folder.
    private func act(_ action: (ResultActions, NodeID) -> Void) {
        guard let model = router.frontModel else { return }
        action(ResultActions(model: model, router: router), model.actionTarget ?? model.currentNode)
    }

    /// Runs `action` on the current folder.
    private func actOnFolder(_ action: (ResultActions, NodeID) -> Void) {
        guard let model = router.frontModel else { return }
        action(ResultActions(model: model, router: router), model.currentNode)
    }
}
