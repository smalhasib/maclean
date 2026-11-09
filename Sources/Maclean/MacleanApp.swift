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
                     smartClean: appDelegate.smartClean, coordinator: appDelegate.coordinator,
                     updates: appDelegate.updates)
        }
        .defaultSize(WindowRouter.startSize)
        .windowResizability(.contentMinSize)
        .commands {
            AppCommands(registry: appDelegate.registry, router: appDelegate.router, smartClean: appDelegate.smartClean,
                        updates: appDelegate.updates)
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
    /// Scan reads and Smart Clean measures share administrator dialogs through it.
    lazy var adminBatcher = AdminBatcher(runner: AdminRunner(), coordinator: coordinator)
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
            batcher: adminBatcher,
            scanning: { [registry] device in
                registry.all.contains { $0.isScanning && ScanBoundary.forRoot($0.rootPath).allowedDevices.contains(device) }
            })
        controller.registry = registry
        return controller
    }()

    lazy var updates: UpdateController = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        return UpdateController(
            currentVersion: version, bundleURL: Bundle.main.bundleURL, fetch: UpdateFetch.fetch(version: version),
            defaults: .standard, coordinator: coordinator, installer: UpdateInstaller(),
            // Spec §5.3: never during a delete or a Smart Clean run.
            isBusy: { [unowned self] in isRunning },
            // A sheet set while another (Smart Clean's review) is up may never show.
            canPresent: { NSApp.windows.allSatisfy { $0.attachedSheet == nil } },
            // Straight to the runner, not the batcher: the coordinator holds admin
            // jobs while a sheet is up, and the update sheet is.
            installPrivileged: { zip, signature, release, bundleURL in
                try await PrivilegedUpdateInstaller().install(zip: zip, signature: signature, release: release,
                                                             replacing: bundleURL)
            },
            download: UpdateFetch.download(version: version))
    }()

    /// A delete or a Smart Clean clean is in progress.
    var isRunning: Bool {
        if case .cleaning = smartClean.phase { return true }
        return registry.all.contains { $0.isDeleting }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = router   // takes over presenting finished scans before any starts
        registry.batcher = adminBatcher
        AppQuit.dismissSheets = { [unowned self] in coordinator.dismissForQuit() }
        // R11: a sheet raised while the main window is closed (window per scan) brings it back.
        coordinator.onSheetRaised = { [unowned self] in router.showLauncher() }
        // Never relaunch mid-delete.
        coordinator.isBusy = { [unowned self] in isRunning }
        NSWindow.allowsAutomaticWindowTabbing = true
        // Run unbundled (`swift run Maclean`), the process would otherwise get
        // no Dock icon and no focus.
        if Bundle.main.bundleIdentifier == nil {
            NSApplication.shared.setActivationPolicy(.regular)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate()
        // Installed after AppKit's own handler so ours wins.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleQuit(_:withReply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass),
                                                     andEventID: AEEventID(kAEQuitApplication))
        coordinator.launch()
        // SwiftUI builds the menu bar during launch: add the item after it.
        DispatchQueue.main.async {
            self.deleteMenuItem.install()
            // The start window is up by now: check in the background (spec §5.1).
            self.smartClean.checkAtLaunchIfEnabled()
            // Spec §5.1; the sheet waits behind the Full Disk Access sheet. Not unbundled
            // (`swift run`): there is no version to compare and no bundle to update.
            if Bundle.main.bundleIdentifier != nil { self.updates.checkAutomatically() }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        coordinator.becameActive()
    }

    func applicationWillTerminate(_ notification: Notification) {
        smartClean.cancelCheck()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// A SwiftUI sheet makes AppKit refuse a quit Apple Event, and AppKit can't
    /// remove it: only the state that owns it can. System Settings' "Quit &
    /// Reopen" arrives while the Full Disk Access sheet is up, so drop the
    /// coordinator's sheets, wait for SwiftUI to take them down, then quit.
    /// Other sheets (Smart Clean review, summaries) still block, as ⌘Q does.
    @objc func handleQuit(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        AppQuit.quit()
    }

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
    let updates: UpdateController
    @Environment(\.openWindow) private var openWindow
    // `State` used as a type: the `@State` macro's plugin ships only with Xcode.
    private let dropTargeted = State(initialValue: false)

    /// Escape or a click outside; the update sheet also stops its check or download.
    private func dismissSheet() {
        if coordinator.sheet == .update { updates.later() } else { coordinator.dismissSheet() }
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
        // Result windows need none: raising a sheet first brings the main window
        // back if it was closed (the coordinator's `onSheetRaised`, R11).
        // One sheet for both kinds: going from one straight to the other swaps its
        // content instead of dismissing and presenting in one update.
        .sheet(isPresented: Binding(get: { coordinator.sheet != nil },
                                    set: { if !$0 { dismissSheet() } })) {
            switch coordinator.sheet {
            case .fullDiskAccess(let granted):
                FullDiskAccessSheet(granted: granted, refusal: coordinator.relaunchRefusal,
                                    onContinue: coordinator.continueWithoutAccess,
                                    onDismissGranted: coordinator.dismissSheet, onRelaunch: coordinator.relaunch)
                    .interactiveDismissDisabled(!granted)
            case .update:
                UpdateSheet(controller: updates)
                    .interactiveDismissDisabled(updates.state == .installing)
            case nil:
                EmptyView()
            }
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
