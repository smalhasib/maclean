import AppKit
import MacleanCore
import MacleanKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The start screen's data: listed volumes (refreshed on mount/unmount) and
/// starred folders.
@MainActor @Observable final class StartModel {
    struct Volume: Identifiable {
        let entry: VolumeEntry
        let capacity: Capacity?
        var id: String { entry.id }
        /// Used bytes of the volume's container, which a full-disk scan's
        /// progress is measured against.
        var usedBytes: Int64? { capacity.map { max(0, $0.total - $0.freeIncludingPurgeable) } }
    }

    private(set) var volumes: [Volume] = []
    private(set) var starred: [String] = []
    @ObservationIgnored private let store: StarredFolders
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard) {
        store = StarredFolders(defaults: defaults)
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    func refresh() {
        let entries = VolumeList.entries(from: ScanBoundary.mounts(), volumeName: Self.volumeName)
        volumes = entries.map { Volume(entry: $0, capacity: VolumeCapacity.of(path: $0.scanPath)) }
        starred = store.resolve()
    }

    func star(_ url: URL) {
        store.star(url)
        starred = store.paths
    }

    func unstar(_ path: String) {
        store.unstar(path)
        starred = store.paths
    }

    private static func volumeName(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        if let name = try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName {
            return name
        }
        return FileManager.default.displayName(atPath: path)
    }
}

@MainActor enum FolderPicker {
    /// Asks for a folder to scan (directories only).
    static func pick() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Scan"
        panel.message = "Choose a folder to scan"
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
    // `State` used as a type: the `@State` macro's plugin ships only with Xcode.
    private let starTargeted = State(initialValue: false)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Disks")
                ForEach(model.volumes) { volume in
                    VolumeRowView(
                        icon: NSWorkspace.shared.icon(forFile: volume.entry.scanPath),
                        title: volume.entry.name,
                        detail: volume.capacity.map {
                            "\(SizeText.string($0.total)) · \(SizeText.string($0.freeIncludingPurgeable)) free"
                        },
                        usage: volume.capacity.flatMap { cap in
                            cap.total > 0 ? Double(volume.usedBytes ?? 0) / Double(cap.total) : nil
                        },
                        path: volume.entry.scanPath,
                        expected: volume.usedBytes,
                        registry: registry)
                    Divider().padding(.leading, 64)
                }

                starredSection
                    .padding(.top, 12)

                HStack(spacing: 12) {
                    Button("Scan Folder…") { FolderPicker.scan(into: registry) }
                    Text("or drop a folder here")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .padding(.vertical, 8)
        }
        .font(.body)
    }

    private var starredSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Starred")
            if model.starred.isEmpty {
                Text("Drop a folder here to star it")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            ForEach(model.starred, id: \.self) { path in
                VolumeRowView(
                    icon: NSWorkspace.shared.icon(forFile: path),
                    title: FileManager.default.displayName(atPath: path),
                    detail: (path as NSString).abbreviatingWithTildeInPath,
                    usage: nil,
                    path: path,
                    expected: nil,
                    registry: registry)
                .contextMenu {
                    Button("Unstar") { model.unstar(path) }
                }
                Divider().padding(.leading, 64)
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
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }
}
