import AppKit
import MacleanKit
import SwiftUI

/// A start-screen row (a disk or a starred folder): icon, name, detail line,
/// thin usage bar, Scan/View button and a ▾ menu. While scanning, the bar
/// becomes a progress bar and Cancel replaces Scan.
struct VolumeRowView: View {
    enum Detail {
        /// Sizes ("494 GB · 77 GB free"): never truncated.
        case size(String)
        /// A display path, truncated in the middle with the full path as tooltip.
        case path(String, full: String)
    }

    let icon: NSImage
    let title: String
    let detail: Detail?
    /// The detail as VoiceOver reads it ("494 gigabytes capacity, 77 gigabytes free").
    var spokenDetail: String?
    /// Used fraction of the volume (0…1), nil for folders.
    let usage: Double?
    /// Canonical path the row scans (the registry key).
    let path: String
    /// Bytes progress is measured against; nil shows indeterminate progress.
    let expected: Int64?
    let registry: SessionRegistry
    @Environment(\.windowRouter) private var router
    // `State` used as a type: the `@State` macro's plugin ships only with Xcode.
    /// Collected items Forget Scan Result asks about (nil: no question showing).
    private let forgetCount = State<Int?>(initialValue: nil)

    /// ⌥-click on Scan or View opens the result in its own window.
    private var optionDown: Bool { NSEvent.modifierFlags.contains(.option) }

    var body: some View {
        let session = registry.session(canonical: path)
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(title)
                        if let detail, !(session?.isScanning ?? false) {
                            detailText(detail)
                        }
                    }
                    status(session)
                }
            }
            // VoiceOver: name, capacity and free space (or path), then state;
            // the buttons stay separate elements.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenText(session))
            .accessibilityAddTraits(.isStaticText)
            Spacer(minLength: 8)
            actions(session)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func spokenText(_ session: ScanSession?) -> String {
        let state: String
        switch session?.state {
        case .scanning(let bytes, _):
            state = session?.isStopping == true ? "stopping" : "scanning, \(SizeText.spoken(bytes)) counted"
        case .finished(let tree): state = "scanned, \(SizeText.spoken(tree.size(of: tree.root)))"
        case .failed(let message): state = "error: \(message)"
        case .cancelled, nil: state = "not scanned"
        }
        return [title, spokenDetail, state].compactMap { $0 }.joined(separator: ", ")
    }

    @ViewBuilder
    private func detailText(_ detail: Detail) -> some View {
        switch detail {
        case .size(let text):
            Text(text)
                .secondaryText()
                .monospacedDigit()
                .fixedSize()
                .layoutPriority(1)
        case .path(let text, let full):
            Text(text)
                .secondaryText()
                .lineLimit(1)
                .truncationMode(.middle)
                .help(full)
        }
    }

    @ViewBuilder
    private func status(_ session: ScanSession?) -> some View {
        switch session?.state {
        case .scanning(let bytes, let expected):
            VStack(alignment: .leading, spacing: 4) {
                if let expected, expected > 0 {
                    ProgressView(value: Double(min(bytes, expected)), total: Double(expected))
                } else {
                    ProgressView()
                }
                Text(session?.isStopping == true ? "Stopping…" : "Scanning… \(SizeText.string(bytes))")
                    .secondaryText()
                    .monospacedDigit()
                    .fixedSize()
            }
            .progressViewStyle(.linear)
            .controlSize(.small)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .secondaryText()
        case .finished(let tree):
            usageBar
            Text("Scanned: \(SizeText.string(tree.size(of: tree.root)))")
                .secondaryText()
                .monospacedDigit()
                .fixedSize()
        case .cancelled, nil:
            usageBar
        }
    }

    @ViewBuilder
    private var usageBar: some View {
        if let usage {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(nsColor: .separatorColor))
                    Capsule().fill(Color.secondary)
                        .frame(width: geo.size.width * min(max(usage, 0), 1))
                }
            }
            .frame(height: 4)
        }
    }

    @ViewBuilder
    private func actions(_ session: ScanSession?) -> some View {
        HStack(spacing: 4) {
            if let session, session.isScanning {
                Button(session.isStopping ? "Stopping…" : "Cancel") { session.cancel() }
                    .disabled(session.isStopping)
            } else if let session, session.tree != nil {
                Button("View") {
                    if let router {
                        router.show(session: session, at: nil, forceNewWindow: optionDown)
                    } else {
                        registry.presented = session
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Scan") { registry.startScan(path: path, expected: expected, newWindow: optionDown) }
                    .buttonStyle(.borderedProminent)
            }
            Menu {
                Button("Rescan") {
                    if session != nil {
                        registry.rescan(canonical: path)
                    } else {
                        registry.startScan(path: path, expected: expected)
                    }
                }
                .disabled(session?.isScanning ?? false)
                Divider()
                Button("Show in Finder") { report(Actions.showInFinder(path)) }
                Button("Get Info") {
                    let start = router?.startModel
                    report(Actions.getInfo(path) { start?.report(Actions.finderPermissionMessage) })
                }
                Divider()
                Button("Forget Scan Result") { forget(session) }
                    .disabled(session.map(\.isScanning) ?? true)
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More")
        }
        .frame(minWidth: 120, alignment: .trailing)
        .alert("Forget this scan?", isPresented: Binding(
            get: { forgetCount.wrappedValue != nil },
            set: { if !$0 { forgetCount.wrappedValue = nil } }
        )) {
            Button("Forget", role: .destructive) { registry.forget(path: path) }
            Button("Cancel", role: .cancel) {}
        } message: {
            let n = forgetCount.wrappedValue ?? 0
            Text(n == 1 ? "1 collected item will be removed from the collector."
                 : "\(n.formatted()) collected items will be removed from the collector.")
        }
    }

    /// Forget Scan Result: asks first when the session's collector holds items.
    private func forget(_ session: ScanSession?) {
        let count = session?.view?.collected.count ?? 0
        if count > 0 {
            forgetCount.wrappedValue = count
        } else {
            registry.forget(path: path)
        }
    }

    private func report(_ result: ActionResult) {
        if result == .missing { router?.startModel.reportMissing(title) }
    }
}
