import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// An item of a scan result dragged inside Maclean (declared in Info.plist).
    /// Drags carry only this type, never a file URL, so a drop on Finder or
    /// another app can't move or copy the real file.
    static let macleanNode = UTType(exportedAs: "org.maclean.node", conformingTo: .data)
}

extension NSPasteboard.PasteboardType {
    static let macleanNode = NSPasteboard.PasteboardType(UTType.macleanNode.identifier)
}

/// What a dragged item carries: its session and path, as JSON.
struct NodeDragPayload: Codable, Equatable, Sendable {
    let sessionID: UUID
    let path: String

    var data: Data { (try? JSONEncoder().encode(self)) ?? Data() }

    init(sessionID: UUID, path: String) {
        self.sessionID = sessionID
        self.path = path
    }

    init?(data: Data) {
        guard let payload = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = payload
    }
}

/// Drag plumbing shared by the chart, the list and the collector panel.
@MainActor enum NodeDrag {
    /// The payload of the drag in progress inside Maclean, set when it starts.
    /// Drop targets read it to decide synchronously whether to light up (the
    /// pasteboard data itself is only read on drop).
    static var current: NodeDragPayload?

    /// An item provider for a SwiftUI `.onDrag` (list and panel rows):
    /// only `org.maclean.node` data, no file URL.
    static func provider(for payload: NodeDragPayload) -> NSItemProvider {
        current = payload
        installEndMonitor()
        let provider = NSItemProvider()
        let data = payload.data
        provider.registerDataRepresentation(forTypeIdentifier: UTType.macleanNode.identifier,
                                            visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    @MainActor private static var endMonitor: Any?

    /// SwiftUI's `.onDrag` reports no end, so `current` is cleared by the
    /// first ordinary event after the drag (the drag loop swallows events
    /// while it runs; a new drag starts after its own mouse-down).
    private static func installEndMonitor() {
        guard endMonitor == nil else { return }
        endMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
        ) { event in
            MainActor.assumeIsolated { current = nil }
            return event
        }
    }

    /// Loads the payloads and file URLs of a drop's providers, on the main actor.
    static func load(_ providers: [NSItemProvider],
                     completion: @escaping @MainActor (_ nodes: [NodeDragPayload], _ files: [String]) -> Void) {
        let group = DispatchGroup()
        let box = LoadBox()
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.macleanNode.identifier) {
                group.enter()
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.macleanNode.identifier) { data, _ in
                    if let data, let payload = NodeDragPayload(data: data) { box.add(node: payload) }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    // A file-reference URL (/.file/id=…) becomes a path URL first.
                    if let url, let path = (url as NSURL).filePathURL?.path { box.add(file: path) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { completion(box.nodes, box.files) }
        }
    }

    /// Collects provider results from background callbacks.
    private final class LoadBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _nodes: [NodeDragPayload] = []
        private var _files: [String] = []

        func add(node: NodeDragPayload) { lock.withLock { _nodes.append(node) } }
        func add(file: String) { lock.withLock { _files.append(file) } }
        var nodes: [NodeDragPayload] { lock.withLock { _nodes } }
        var files: [String] { lock.withLock { _files } }
    }
}

/// Drop target of the collector bar: Maclean items from this session, and
/// files from Finder (resolved by path inside the scan).
struct CollectorDropDelegate: DropDelegate {
    let model: ResultViewModel
    let targeted: Binding<Bool>

    func validateDrop(info: DropInfo) -> Bool {
        guard !model.session.isDeleting else { return false }
        if info.hasItemsConforming(to: [.macleanNode]) {
            return NodeDrag.current.map(model.canCollect) ?? false
        }
        return info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) { targeted.wrappedValue = true }
    func dropExited(info: DropInfo) { targeted.wrappedValue = false }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }

    func performDrop(info: DropInfo) -> Bool {
        targeted.wrappedValue = false
        NodeDrag.current = nil
        let model = self.model
        let maclean = info.itemProviders(for: [.macleanNode])
        let providers = maclean.isEmpty ? info.itemProviders(for: [.fileURL]) : maclean
        NodeDrag.load(providers) { nodes, files in
            let ids = nodes.compactMap { model.canCollect($0) ? model.node(for: $0) : nil }
            if !ids.isEmpty { model.collect(ids) }
            if !files.isEmpty { model.collectDropped(paths: files) }
        }
        return true
    }
}

/// Drop target of the chart: a collected item dragged out of the collector
/// panel is put back.
struct ChartDropDelegate: DropDelegate {
    let model: ResultViewModel
    let targeted: Binding<Bool>

    func validateDrop(info: DropInfo) -> Bool {
        guard !model.session.isDeleting, info.hasItemsConforming(to: [.macleanNode]) else { return false }
        return NodeDrag.current.map(model.isCollected) ?? false
    }

    func dropEntered(info: DropInfo) { targeted.wrappedValue = true }
    func dropExited(info: DropInfo) { targeted.wrappedValue = false }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }

    func performDrop(info: DropInfo) -> Bool {
        targeted.wrappedValue = false
        NodeDrag.current = nil
        let model = self.model
        NodeDrag.load(info.itemProviders(for: [.macleanNode])) { nodes, _ in
            let ids = nodes.compactMap { model.isCollected($0) ? model.node(for: $0) : nil }
            if !ids.isEmpty { model.session.uncollect(ids) }
        }
        return true
    }
}
