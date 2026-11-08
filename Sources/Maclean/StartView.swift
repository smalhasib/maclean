import AppKit
import MacleanCore
import MacleanKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The start screen's data: listed volumes (refreshed on mount/unmount) and
/// starred folders. File-system work (capacities, volume names, bookmark
/// resolution) runs off the main actor; rows carry canonical paths so views
/// never call `realpath`.
@MainActor @Observable final class StartModel {
    struct Volume: Identifiable, Sendable {
        let entry: VolumeEntry
        let capacity: Capacity?
        var id: String { entry.id }
        /// Used bytes of the volume's container, which a full-disk scan's
        /// progress is measured against.
        var usedBytes: Int64? { capacity.map { max(0, $0.total - $0.freeIncludingPurgeable) } }
    }

    /// A folder row (starred or scanned): canonical path plus display text.
    struct Folder: Identifiable {
        let path: String
        let name: String
        let detail: String
        var id: String { path }

        init(path: String) {
            self.path = path
            let name = (path as NSString).lastPathComponent
            self.name = name.isEmpty ? path : name
            detail = (path as NSString).abbreviatingWithTildeInPath
        }
    }

    private(set) var volumes: [Volume] = []
    private(set) var starred: [Folder] = []
    /// An inline "… no longer exists" message; `id` restarts its dismiss timer.
    private(set) var notice: (id: UUID, text: String)?
    @ObservationIgnored private let store: StarredFolders
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var icons: [String: NSImage] = [:]

    init(defaults: UserDefaults = .standard) {
        store = StarredFolders(defaults: defaults)
        starred = store.paths.map(Folder.init)
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        // Free space changed after a delete.
        observers.append(NotificationCenter.default.addObserver(forName: .macleanDidDelete, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
    }

    /// Re-reads volumes and re-resolves starred folders in the background,
    /// publishing results on the main actor (stale refreshes are dropped).
    func refresh() {
        generation += 1
        let current = generation
        icons.removeAll()
        Task {
            let volumes = await Task.detached(priority: .userInitiated) { Self.readVolumes() }.value
            guard current == generation else { return }
            self.volumes = volumes
            let paths = await store.resolveInBackground()
            guard current == generation else { return }
            starred = paths.map(Folder.init)
        }
    }

    func reportMissing(_ name: String) {
        report("“\(name)” no longer exists")
    }

    /// Shows an inline message on the start screen.
    func report(_ text: String) {
        notice = (UUID(), text)
    }

    func dismissNotice(_ id: UUID? = nil) {
        if id == nil || notice?.id == id { notice = nil }
    }

    func star(_ url: URL) {
        store.star(url)
        starred = store.paths.map(Folder.init)
    }

    func unstar(_ path: String) {
        store.unstar(path)
        starred = store.paths.map(Folder.init)
    }

    /// Finder icon for `path`, looked up once per refresh.
    func icon(for path: String) -> NSImage {
        if let icon = icons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }

    private nonisolated static func readVolumes() -> [Volume] {
        VolumeList.entries(from: ScanBoundary.mounts(), volumeName: volumeName)
            .map { Volume(entry: $0, capacity: VolumeCapacity.of(path: $0.scanPath)) }
    }

    private nonisolated static func volumeName(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        if let name = try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName {
            return name
        }
        return FileManager.default.displayName(atPath: path)
    }
}

@MainActor enum FolderPicker {
    /// Asks for a folder to scan (directories only).
    static func pick(prompt: String = "Scan", message: String = "Choose a folder to scan") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = prompt
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Picks a folder and starts a fresh scan of it.
    static func scan(into registry: SessionRegistry) {
        if let url = pick() { registry.startScan(path: url.path) }
    }

    static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return url.isFileURL && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

struct StartView: View {
    let model: StartModel
    let registry: SessionRegistry
    let smartClean: SmartCleanController
    // `State` used as a type: the `@State` macro's plugin ships only with Xcode.
    private let starTargeted = State(initialValue: false)
    private let reviewing = State(initialValue: false)
    private static let folderIcon = NSWorkspace.shared.icon(for: .folder)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let notice = model.notice {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").secondaryText()
                        Text(notice.text).lineLimit(1).truncationMode(.middle).help(notice.text)
                        Spacer(minLength: 8)
                        Button { model.dismissNotice() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Dismiss")
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal, 12)
                    .accessibilityElement(children: .combine)
                    .task(id: notice.id) {
                        try? await Task.sleep(for: .seconds(4))
                        model.dismissNotice(notice.id)
                    }
                }
                SectionHeader(title: "Disks")
                ForEach(model.volumes) { volume in
                    VolumeRowView(
                        icon: model.icon(for: volume.entry.scanPath),
                        title: volume.entry.name,
                        detail: volume.capacity.map {
                            .size("\(SizeText.string($0.total)) · \(SizeText.string($0.freeIncludingPurgeable)) free")
                        },
                        spokenDetail: volume.capacity.map {
                            "\(SizeText.spoken($0.total)) capacity, \(SizeText.spoken($0.freeIncludingPurgeable)) free"
                        },
                        usage: volume.capacity.flatMap { cap in
                            cap.total > 0 ? Double(volume.usedBytes ?? 0) / Double(cap.total) : nil
                        },
                        path: volume.entry.scanPath,
                        expected: volume.usedBytes,
                        registry: registry)
                    Separator().padding(.leading, 64)
                }

                // This view isn't on screen while a result fills the window (one-window mode).
                SmartCleanCard(controller: smartClean) { reviewing.wrappedValue = true }

                let folders = scannedFolders
                if !folders.isEmpty {
                    SectionHeader(title: "Scanned Folders")
                        .padding(.top, 12)
                    ForEach(folders) { folder in
                        folderRow(folder, icon: Self.folderIcon)
                            .contextMenu {
                                Button("Star Folder") { model.star(URL(fileURLWithPath: folder.path)) }
                            }
                        Separator().padding(.leading, 64)
                    }
                }

                starredSection
                    .padding(.top, 12)

                HStack(spacing: 12) {
                    Button("Scan Folder…") { FolderPicker.scan(into: registry) }
                    Text("or drop a folder here")
                        .secondaryText()
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .padding(.vertical, 8)
        }
        .font(.body)
        // Stays up through confirming, cleaning and the summary, even if the view is rebuilt meanwhile.
        .sheet(isPresented: Binding(get: { reviewing.wrappedValue || smartClean.isBusyCleaning },
                                    set: { if !$0 { reviewing.wrappedValue = false } })) {
            SmartCleanReviewView(controller: smartClean) { reviewing.wrappedValue = false }
                .interactiveDismissDisabled(smartClean.isBusyCleaning)
        }
    }

    /// This session's scans that aren't a listed disk or a starred folder.
    private var scannedFolders: [StartModel.Folder] {
        var listed = Set(model.volumes.map(\.entry.scanPath))
        listed.formUnion(model.starred.map(\.path))
        return registry.all.map(\.rootPath).filter { !listed.contains($0) }.map(StartModel.Folder.init)
    }

    private func folderRow(_ folder: StartModel.Folder, icon: NSImage) -> VolumeRowView {
        VolumeRowView(icon: icon, title: folder.name, detail: .path(folder.detail, full: folder.path),
                      spokenDetail: folder.detail, usage: nil, path: folder.path, expected: nil, registry: registry)
    }

    private var starredSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Starred")
            if model.starred.isEmpty {
                Text("Drop a folder here to star it")
                    .secondaryText()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            ForEach(model.starred) { folder in
                folderRow(folder, icon: model.icon(for: folder.path))
                    .contextMenu {
                        Button("Unstar") { model.unstar(folder.path) }
                    }
                Separator().padding(.leading, 64)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(starTargeted.wrappedValue ? Color.accentColor.opacity(0.08) : .clear)
                .padding(.horizontal, 8)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter(FolderPicker.isFolder)
            for folder in folders { model.star(folder) }
            return !folders.isEmpty
        } isTargeted: { starTargeted.wrappedValue = $0 }
    }
}

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .secondaryText()
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }
}
