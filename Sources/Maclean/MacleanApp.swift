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
            RootView(model: appDelegate.startModel, registry: appDelegate.registry, router: appDelegate.router,
                     smartClean: appDelegate.smartClean, coordinator: appDelegate.coordinator)
        }
        .defaultSize(WindowRouter.startSize)
        .windowResizability(.contentMinSize)
        .commands {
            AppCommands(registry: appDelegate.registry, router: appDelegate.router, smartClean: appDelegate.smartClean)
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
    let coordinator = PromptCoordinator(hasAccess: { FullDiskAccess.isGranted() })
    private lazy var deleteMenuItem = DeleteMenuItem(router: router)
    lazy var smartClean: SmartCleanController = {
        let controller = SmartCleanController(
            // A fresh probe per check: it caches the open-files snapshot.
            engine: { CleanEngine(rules: CleanCatalog.rules, home: NSHomeDirectory(), environment: .current(),
                                  probes: LiveCleanProbes()) },
            probes: LiveCleanProbes(),
            // The never-clean list guards the delete path too (read when each clean starts).
            makeDeleter: { mode, context in
                let neverClean = UserDefaults.standard.stringArray(forKey: SmartCleanController.neverCleanKey) ?? []
                return Deleter(mode: mode, environment: DeleteBatch.environment(for: context, neverClean: neverClean),
                               context: context)
            },
            admin: AdminRunner(),
            scanning: { [registry] device in
                registry.all.contains { $0.isScanning && ScanBoundary.forRoot($0.rootPath).allowedDevices.contains(device) }
            })
        controller.registry = registry
        return controller
    }()

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
        coordinator.launch()
        // SwiftUI builds the menu bar during launch: add the item after it.
        DispatchQueue.main.async {
            self.deleteMenuItem.install()
            // The start window is up by now: check in the background (spec §5.1).
            self.smartClean.checkAtLaunchIfEnabled()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        coordinator.becameActive()
    }

    func applicationWillTerminate(_ notification: Notification) {
        smartClean.cancelCheck()
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
    let smartClean: SmartCleanController
    let coordinator: PromptCoordinator
    @Environment(\.openWindow) private var openWindow
    // `State` used as a type: the `@State` macro's plugin ships only with Xcode.
    private let dropTargeted = State(initialValue: false)

    /// The update sheet has its own presentation (a later task).
    private static func showsAccessSheet(_ sheet: PromptCoordinator.Sheet?) -> Bool {
        if case .fullDiskAccess = sheet { return true }
        return false
    }

    var body: some View {
        Group {
            if let session = registry.presented, let tree = session.tree,
               let result = router.mainResults.model(for: session, tree: tree) {
                ResultView(model: result, router: router) { router.backToDisks(from: result) }
                    .id(ObjectIdentifier(result))
            } else {
                StartView(model: model, registry: registry, smartClean: smartClean, coordinator: coordinator)
            }
        }
        .frame(minWidth: WindowRouter.startMinimumSize.width, minHeight: WindowRouter.startMinimumSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(MainWindowAccessor(router: router))
        .environment(\.windowRouter, router)
        // The coordinator's sheet gates admin jobs app-wide, so it is presented here, on
        // whatever fills the main window (start screen or a result), never on one view.
        // Result windows need none: the main window is always open while the app runs.
        .sheet(isPresented: Binding(get: { Self.showsAccessSheet(coordinator.sheet) },
                                    set: { if !$0 { coordinator.dismissSheet() } })) {
            let granted = coordinator.sheet == .fullDiskAccess(granted: true)
            FullDiskAccessSheet(granted: granted, onContinue: coordinator.continueWithoutAccess,
                                onDismissGranted: coordinator.dismissSheet)
                .interactiveDismissDisabled(!granted)
        }
        .onAppear {
            let open = openWindow
            router.openMainWindow = { open(id: "main") }
        }
        // Spec §5.4: the window resizes back to the compact list.
        .onChange(of: registry.presented == nil) { _, onStart in
            if onStart { router.shrinkMainWindowToStart() }
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
