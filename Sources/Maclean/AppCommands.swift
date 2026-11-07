import AppKit
import MacleanCore
import SwiftUI

/// Where Help points. A placeholder until the GitHub repository exists.
enum ProjectLinks {
    static let repository = URL(string: "https://github.com/maclean-app/maclean")!
    static let help = repository.appending(path: "blob/main/README.md")
    static let issues = repository.appending(path: "issues/new")
}

/// The menu bar (spec §6). App, Edit, View (Enter Full Screen) and Window
/// (with tabbing) are the standard ones; File, Go, Action and Help are built
/// here. Go and Action act on the result in the main window, and on the item
/// under the pointer or the selection where that applies (spec §5.3),
/// falling back to the current folder.
struct AppCommands: Commands {
    let registry: SessionRegistry
    let router: WindowRouter

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Scan Folder…") { FolderPicker.scan(into: registry) }
                .keyboardShortcut("o")
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
            Button("Maclean Help") { NSWorkspace.shared.open(ProjectLinks.help) }
            Button("Report an Issue") { NSWorkspace.shared.open(ProjectLinks.issues) }
        }
    }
}

/// A view so the items observe the router's active result.
private struct GoMenu: View {
    let router: WindowRouter
    @AppStorage(ResultViewModel.alwaysExpandKey) private var alwaysExpand = false

    var body: some View {
        let model = router.activeModel
        Button("Back") { model?.back() }
            .keyboardShortcut("[")
            .disabled(!(model?.history.canGoBack ?? false))
        Button("Forward") { model?.forward() }
            .keyboardShortcut("]")
            .disabled(!(model?.history.canGoForward ?? false))
        Button("Enclosing Folder") { model?.goUp() }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(model.map { $0.tree.parent(of: $0.currentNode) == nil } ?? true)
        Button("Back to Disks") { if let model { router.backToDisks(from: model) } }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(model == nil)
        Divider()
        Button("Expand “smaller objects”") { model?.toggleSmallerObjects() }
            .keyboardShortcut("e")
            .disabled(!(model?.hasSmallerObjects ?? false))
        Toggle("Always Expand “smaller objects”", isOn: Binding(
            get: { alwaysExpand },
            set: { router.setAlwaysExpand($0) }))
    }
}

private struct ActionMenu: View {
    let router: WindowRouter

    var body: some View {
        let model = router.activeModel
        let scanning = model?.session.isScanning ?? true
        Button("Rescan Current Folder") { if let model { router.rescan(model) } }
            .keyboardShortcut("r")
            .disabled(scanning)
        Button("Rescan") { if let model { router.rescanDisk(model) } }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model == nil)
        Divider()
        Button("Show Current Folder in Finder") {
            if let model { ResultActions(model: model, router: router).showInFinder(target(model)) }
        }
        .keyboardShortcut("r", modifiers: [.command, .option])
        .disabled(model == nil)
        Button("Open Current Folder in Terminal") {
            if let model { ResultActions(model: model, router: router).openInTerminal(target(model)) }
        }
        .keyboardShortcut("t", modifiers: [.command, .option])
        .disabled(model == nil)
        Divider()
        Button("Launch Disk Utility…") { Actions.launchDiskUtility() }
    }

    /// The item under the pointer or the selection, else the current folder.
    private func target(_ model: ResultViewModel) -> NodeID {
        model.actionTarget ?? model.currentNode
    }
}
