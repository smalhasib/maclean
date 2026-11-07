import AppKit
import MacleanCore
import MacleanKit
import Observation
import SwiftUI

/// Decides where a result is shown (spec §5.4) and tracks the result shown in
/// each window.
///
/// - One window (default): the start screen and a result share the main
///   window (`SessionRegistry.presented`).
/// - Window per scan (Settings › "Open each scan in its own window", read
///   when a window is about to open): each Scan or View opens or brings
///   forward that result's own window; the main window is the launcher.
/// - Both modes: Open in New Window (or ⌥-click) opens a folder in its own
///   window, reusing the tree.
///
/// A window is identified by (session, node): a request for a path that a
/// window shows now (even minimized or in a background tab) brings that
/// window forward instead of opening another.
@MainActor @Observable final class WindowRouter {
    static let ownWindowKey = "openEachScanInOwnWindow"
    static let tabbingIdentifier = "org.maclean.result"

    let registry: SessionRegistry
    let startModel: StartModel

    /// Opens (or re-opens) the SwiftUI main window; set by the main window's root view.
    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored weak var mainWindow: NSWindow?
    /// The main window's result model. Owned here (not by the view) so
    /// Forget Scan Result can release the tree.
    @ObservationIgnored let mainResults = ResultModelCache()

    private struct Entry {
        weak var window: NSWindow?
        let model: ResultViewModel
    }
    @ObservationIgnored private var entries: [ObjectIdentifier: Entry] = [:]
    /// Result windows the router created (kept alive until closed), with
    /// the session each shows.
    private struct Owned {
        let window: NSWindow
        let session: ScanSession
    }
    @ObservationIgnored private var owned: [ObjectIdentifier: Owned] = [:]
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private let defaults: UserDefaults
    /// The start screen's content size, once the user resized the main
    /// window while it showed the start screen; "Disks" returns to it.
    @ObservationIgnored private var compactSize: CGSize?

    /// The start screen's default and minimum content sizes.
    static let startSize = CGSize(width: 560, height: 420)
    static let startMinimumSize = CGSize(width: 520, height: 300)

    init(registry: SessionRegistry, startModel: StartModel, defaults: UserDefaults = .standard) {
        self.registry = registry
        self.startModel = startModel
        self.defaults = defaults
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) {
            [weak self] note in
            let id = (note.object as? NSWindow).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { if let id { self?.windowWillClose(id) } }
        })
        observers.append(center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let id = (note.object as? NSWindow).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { if let id { self?.windowDidEndLiveResize(id) } }
        })
        registry.onFinish = { [weak self] session, newWindow in self?.presentFinished(session, newWindow: newWindow) }
        registry.onUserScan = { [weak self] in self?.userScanStarted() }
        registry.onForget = { [weak self] session in self?.forgotten(session) }
    }

    var opensOwnWindows: Bool { defaults.bool(forKey: Self.ownWindowKey) }

    // MARK: Showing results

    /// Shows `session` at `path` (its root when nil): in the main window, or
    /// with `forceNewWindow` or the window-per-scan setting, in that result's
    /// own window (brought forward if one already shows it).
    func show(session: ScanSession, at path: String?, forceNewWindow: Bool) {
        guard let tree = session.tree else { return }
        let requested = path
        let path = path ?? tree.rootPath
        if !forceNewWindow && !opensOwnWindows {
            registry.presented = session
            if let model = activeModelInMainWindow(), model.session === session, path != tree.rootPath {
                model.visit(path: path)
            }
            showLauncher()
            return
        }
        if let window = window(showing: session, at: path, anyFolder: requested == nil) {
            bringForward(window)
            return
        }
        openWindow(session: session, at: path)
    }

    /// Forget Scan Result: the main window lets go of the session's model,
    /// and the windows showing it close (their result is gone).
    private func forgotten(_ session: ScanSession) {
        mainResults.drop(session: session)
        for item in owned.values where item.session === session {
            item.window.close()
        }
    }

    /// A scan finished: a window already showing the session (now remapped to
    /// the new tree) comes forward; otherwise the result opens per the mode.
    private func presentFinished(_ session: ScanSession, newWindow: Bool) {
        // The main window went back to this result (rescan from there).
        if registry.presented === session {
            showLauncher()
            return
        }
        if let entry = entries.values.first(where: { $0.model.session === session }), let window = entry.window {
            bringForward(window)
            return
        }
        if newWindow || opensOwnWindows {
            show(session: session, at: nil, forceNewWindow: true)
        } else if registry.presented == nil {
            registry.presented = session
            showLauncher()
        }
    }

    /// A user-started scan (Scan, Scan Folder…, drop): its progress shows on
    /// the start screen, so the launcher comes forward in window-per-scan mode.
    private func userScanStarted() {
        if opensOwnWindows { showLauncher() }
    }

    /// Brings the main window (start screen or launcher) forward, re-opening it if closed.
    func showLauncher() {
        if let mainWindow, mainWindow.isVisible || mainWindow.isMiniaturized {
            bringForward(mainWindow)
        } else {
            openMainWindow?()
        }
    }

    /// "Disks" / ⇧⌘D from a result: the main window goes back to the start
    /// screen; another window brings the launcher forward.
    func backToDisks(from model: ResultViewModel) {
        if registry.presented === model.session, entry(for: model)?.window === mainWindow {
            registry.presented = nil
        }
        showLauncher()
    }

    /// One-window mode, back on the start screen: the main window shrinks
    /// (animated, top-left fixed; instantly with Reduce Motion) to the start
    /// screen's size, or the size the user last gave the start screen.
    /// Never grows, and leaves a full-screen window alone.
    func shrinkMainWindowToStart() {
        // After SwiftUI has swapped in the start screen and relaxed the
        // result's minimum size.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = mainWindow, window.isVisible,
                  !window.styleMask.contains(.fullScreen), registry.presented == nil else { return }
            let target = compactSize ?? Self.startSize
            let content = window.contentRect(forFrameRect: window.frame).size
            let want = CGSize(width: max(min(content.width, target.width), Self.startMinimumSize.width),
                              height: max(min(content.height, target.height), Self.startMinimumSize.height))
            guard want != content else { return }
            var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: want))
            frame.origin.x = window.frame.minX
            frame.origin.y = window.frame.maxY - frame.height
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                window.setFrame(frame, display: true)
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.3
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    window.animator().setFrame(frame, display: true)
                }
            }
        }
    }

    /// Sets "Always Expand smaller objects" in every open result (and the default).
    func setAlwaysExpand(_ on: Bool) {
        defaults.set(on, forKey: ResultViewModel.alwaysExpandKey)
        for entry in entries.values { entry.model.expandSmallerObjects = on }
    }

    // MARK: Rescans

    /// ⌘R: rescans the session root in full; every window on it remaps by
    /// path. A no-op while the session deletes.
    func rescan(_ model: ResultViewModel) {
        registry.rescan(canonical: model.session.rootPath)
    }

    /// ⇧⌘R: rescans the volume the result lives on. A no-op while the
    /// result's session deletes.
    func rescanDisk(_ model: ResultViewModel) {
        guard !model.session.isDeleting else { return }
        let root = model.tree.rootPath
        let volume = startModel.volumes
            .filter { PathUtil.isInside(root, orEqualTo: $0.entry.scanPath) }
            .max { $0.entry.scanPath.count < $1.entry.scanPath.count }
        let path = volume?.entry.scanPath ?? Self.volumePath(of: root) ?? root
        if let session = registry.session(for: path), session.tree != nil {
            registry.rescan(canonical: session.rootPath)
        } else {
            registry.startScan(path: path, expected: volume?.usedBytes)
        }
    }

    // MARK: Window registration (ResultWindowBridge)

    func register(model: ResultViewModel, window: NSWindow) {
        let id = ObjectIdentifier(window)
        if let existing = entries[id], existing.model === model { return }
        entries[id] = Entry(window: window, model: model)
    }

    func unregister(model: ResultViewModel, window: NSWindow?) {
        defer { checkWindows(of: model.session) }
        guard let window else {
            entries = entries.filter { $0.value.model !== model }
            return
        }
        let id = ObjectIdentifier(window)
        if entries[id]?.model === model { entries[id] = nil }
    }

    /// A delete must stay visible: once no result window shows its session
    /// (checked a turn later, so a view moving between windows doesn't
    /// count), a countdown is cancelled and a run stops after the current item.
    private func checkWindows(of session: ScanSession) {
        guard session.isDeleting else { return }
        DispatchQueue.main.async { [weak self, weak session] in
            guard let self, let session, session.isDeleting,
                  !self.entries.values.contains(where: { $0.model.session === session && $0.window != nil })
            else { return }
            session.deletionController?.noWindowLeft()
        }
    }

    /// The result in the front document window (the main window, which stays
    /// put while the Quick Look panel is key), looked up when a menu item is
    /// chosen; nil on the start screen.
    var frontModel: ResultViewModel? {
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow else { return nil }
        return entries[ObjectIdentifier(window)]?.model
    }

    // MARK: Private

    /// Brings `window` forward even when it is minimized or a background tab.
    private func bringForward(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        if let group = window.tabGroup, group.selectedWindow !== window { group.selectedWindow = window }
        window.makeKeyAndOrderFront(nil)
    }

    private func activeModelInMainWindow() -> ResultViewModel? {
        mainWindow.flatMap { entries[ObjectIdentifier($0)]?.model }
    }

    private func entry(for model: ResultViewModel) -> Entry? {
        entries.values.first { $0.model === model }
    }

    /// A window showing `session` at `path` now (minimized or a background
    /// tab included): one window per (tree, node). With `anyFolder` (View),
    /// a window on the session in another folder is used when none is at `path`.
    private func window(showing session: ScanSession, at path: String, anyFolder: Bool = false) -> NSWindow? {
        let onSession = entries.values.filter { $0.model.session === session && $0.window != nil }
        if let exact = onSession.first(where: { $0.model.history.current == path }) { return exact.window }
        return anyFolder ? onSession.first?.window : nil
    }

    private func openWindow(session: ScanSession, at path: String) {
        let cache = ResultModelCache(startPath: path, ownsSessionHistory: false)
        let content = ResultWindowContent(session: session, cache: cache, router: self)
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .automatic
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.title = Self.title(for: path)
        window.setContentSize(ResultView.minimumSize)
        if let anchor = NSApp.mainWindow ?? mainWindow {
            window.setFrameTopLeftPoint(NSPoint(x: anchor.frame.minX + 24, y: anchor.frame.maxY - 24))
        } else {
            window.center()
        }
        let id = ObjectIdentifier(window)
        owned[id] = Owned(window: window, session: session)
        window.makeKeyAndOrderFront(nil)
    }

    /// Remembers a size the user gave the start screen.
    private func windowDidEndLiveResize(_ id: ObjectIdentifier) {
        guard let window = mainWindow, ObjectIdentifier(window) == id, registry.presented == nil,
              !window.styleMask.contains(.fullScreen) else { return }
        compactSize = window.contentRect(forFrameRect: window.frame).size
    }

    private func windowWillClose(_ id: ObjectIdentifier) {
        if let session = entries.removeValue(forKey: id)?.model.session { checkWindows(of: session) }
        if let window = owned.removeValue(forKey: id)?.window {
            // Release the SwiftUI content (and its tree) with the window.
            DispatchQueue.main.async { window.contentViewController = nil }
        }
    }

    static func title(for path: String) -> String {
        let name = FileManager.default.displayName(atPath: path)
        return name.isEmpty ? path : name
    }

    private static func volumePath(of path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        return (try? url.resourceValues(forKeys: [.volumeURLKey]).volume)?.path
    }
}

/// Content of a result window the router opened: the session's result,
/// remapped by path whenever a rescan replaces the tree. While a rescan runs
/// (or after it failed) the previous result stays up with a banner.
struct ResultWindowContent: View {
    let session: ScanSession
    let cache: ResultModelCache
    let router: WindowRouter

    var body: some View {
        Group {
            if let model = cache.model(for: session, tree: session.tree) {
                ResultView(model: model, router: router) { router.backToDisks(from: model) }
                    .id(ObjectIdentifier(model))
            } else {
                Text("This result is no longer available")
                    .secondaryText()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: ResultView.minimumSize.width, minHeight: ResultView.minimumSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Registers a result view's model with the router for its window, inserts
/// the Quick Look controller into the window's responder chain, and keeps
/// the title of router-opened windows on the current folder.
struct ResultWindowBridge: NSViewRepresentable {
    let model: ResultViewModel
    let router: WindowRouter?
    let title: String

    func makeNSView(context: Context) -> BridgeView {
        let view = BridgeView()
        view.model = model
        view.router = router
        return view
    }

    func updateNSView(_ view: BridgeView, context: Context) {
        if view.model !== model {
            if let old = view.model { router?.unregister(model: old, window: view.window) }
            view.model = model
            view.attach()
        }
        if let window = view.window, window !== router?.mainWindow, window.title != title {
            window.title = title
        }
    }

    static func dismantleNSView(_ view: BridgeView, coordinator: ()) {
        view.detach()
    }

    final class BridgeView: NSView {
        /// Invisible helper: never the target of clicks (it spans the whole
        /// result and would otherwise take right-clicks from SwiftUI's context menus).
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        var model: ResultViewModel?
        weak var router: WindowRouter?
        private weak var attachedWindow: NSWindow?
        private let preview = ResultResponder()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { detach() } else { attach() }
        }

        func attach() {
            guard let window, let model else { return }
            preview.model = model
            preview.router = router
            preview.hostWindow = window
            if attachedWindow !== window {
                detach()
                attachedWindow = window
                // Window → preview responder → whatever followed the window.
                if window.nextResponder !== preview {
                    preview.nextResponder = window.nextResponder
                    window.nextResponder = preview
                }
            }
            router?.register(model: model, window: window)
        }

        func detach() {
            if let window = attachedWindow {
                // Unlink the preview responder wherever it sits in the chain
                // (a newer result view may have inserted its own in front).
                var responder: NSResponder? = window
                while let current = responder {
                    if current.nextResponder === preview {
                        current.nextResponder = preview.nextResponder
                        break
                    }
                    responder = current.nextResponder
                }
                if let model { router?.unregister(model: model, window: window) }
            }
            attachedWindow = nil
        }
    }
}

/// Reports the SwiftUI main window to the router.
struct MainWindowAccessor: NSViewRepresentable {
    let router: WindowRouter

    func makeNSView(context: Context) -> AccessorView {
        let view = AccessorView()
        view.router = router
        return view
    }

    func updateNSView(_ view: AccessorView, context: Context) {}

    final class AccessorView: NSView {
        /// Invisible helper: never the target of clicks (it spans the whole
        /// result and would otherwise take right-clicks from SwiftUI's context menus).
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        weak var router: WindowRouter?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { router?.mainWindow = window }
        }
    }
}
