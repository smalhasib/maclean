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
            RootView(model: appDelegate.startModel, registry: appDelegate.registry, router: appDelegate.router)
        }
        .defaultSize(width: 560, height: 420)
        .windowResizability(.contentMinSize)
        .commands {
            AppCommands(registry: appDelegate.registry, router: appDelegate.router)
        }

        Settings {
            SettingsView()
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let registry = SessionRegistry()
    let startModel = StartModel()
    lazy var router = WindowRouter(registry: registry, startModel: startModel)

    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = router   // takes over presenting finished scans before any starts
        NSWindow.allowsAutomaticWindowTabbing = true
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
    let router: WindowRouter
    @Environment(\.openWindow) private var openWindow
    // `State` used as a type: the `@State` macro's plugin ships only with Xcode.
    private let dropTargeted = State(initialValue: false)

    var body: some View {
        Group {
            if let session = registry.presented, let tree = session.tree,
               let result = router.mainResults.model(for: session, tree: tree) {
                ResultView(model: result, router: router) { router.backToDisks(from: result) }
                    .id(ObjectIdentifier(result))
            } else {
                StartView(model: model, registry: registry)
            }
        }
        .frame(minWidth: 520, minHeight: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(MainWindowAccessor(router: router))
        .environment(\.windowRouter, router)
        .onAppear {
            let open = openWindow
            router.openMainWindow = { open(id: "main") }
        }
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
