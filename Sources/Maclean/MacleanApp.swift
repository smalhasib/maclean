import AppKit
import MacleanCore
import MacleanKit
import SwiftUI

@main
struct MacleanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        ProcessLimits.raiseOpenFileLimit()
    }

    var body: some Scene {
        Window("Maclean", id: "main") {
            RootView(model: appDelegate.startModel, registry: appDelegate.registry)
        }
        .defaultSize(width: 560, height: 420)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Scan Folder…") { FolderPicker.scan(into: appDelegate.registry) }
                    .keyboardShortcut("o")
            }
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let registry = SessionRegistry()
    let startModel = StartModel()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Run unbundled (`swift run Maclean`), the process would otherwise get
        // no Dock icon and no focus.
        if Bundle.main.bundleIdentifier == nil {
            NSApplication.shared.setActivationPolicy(.regular)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Folders dropped on the Dock icon (or opened with the app) are scanned.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where FolderPicker.isFolder(url) {
            registry.startScan(path: url.path)
        }
    }
}

struct RootView: View {
    let model: StartModel
    let registry: SessionRegistry
    // `State` used as a type: the `@State` macro's plugin ships only with Xcode.
    private let dropTargeted = State(initialValue: false)

    var body: some View {
        Group {
            if let session = registry.presented, let tree = session.tree {
                ResultPlaceholderView(tree: tree) { registry.presented = nil }
            } else {
                StartView(model: model, registry: registry)
            }
        }
        .frame(minWidth: 520, minHeight: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if dropTargeted.wrappedValue {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        // Folders dropped anywhere except the Starred section are scanned.
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter(FolderPicker.isFolder)
            for folder in folders { registry.startScan(path: folder.path) }
            return !folders.isEmpty
        } isTargeted: { dropTargeted.wrappedValue = $0 }
    }
}

/// Stand-in for the main window (Task 6): the root's size and its largest
/// children.
struct ResultPlaceholderView: View {
    let tree: FileTree
    let back: () -> Void

    private var topChildren: [NodeID] {
        Array(tree.children(of: tree.root).sorted { tree.size(of: $0) > tree.size(of: $1) }.prefix(20))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Disks", systemImage: "chevron.left", action: back)
                Spacer()
            }
            HStack(alignment: .firstTextBaseline) {
                Text(tree.rootPath)
                    .font(.title2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(tree.rootPath)
                Spacer()
                Text(SizeText.string(tree.size(of: tree.root)))
                    .font(.title2)
                    .monospacedDigit()
            }
            Divider()
            List(topChildren, id: \.self) { child in
                HStack {
                    Text(tree.name(of: child))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(tree.name(of: child))
                    Spacer()
                    Text(SizeText.string(tree.size(of: child)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .listStyle(.plain)
        }
        .padding(20)
    }
}
