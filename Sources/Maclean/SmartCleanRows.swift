import AppKit
import MacleanCore
import MacleanKit
import SwiftUI

/// One offered item in the review (spec §5.2): checkbox (none for Info),
/// icon, name, middle-truncated path, size and age, and the reason.
struct SmartCleanRow: View {
    let controller: SmartCleanController
    let candidate: CleanCandidate
    let scanFolder: (String) -> Void

    var body: some View {
        let c = candidate
        HStack(alignment: .top, spacing: 10) {
            checkbox
            Image(nsImage: NSWorkspace.shared.icon(forFile: c.path))
                .resizable()
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.displayName).lineLimit(1).truncationMode(.middle)
                Text((c.path as NSString).abbreviatingWithTildeInPath)
                    .secondaryText().lineLimit(1).truncationMode(.middle)
                Text(c.reason).secondaryText().fixedSize(horizontal: false, vertical: true)
                if c.tier == .info {
                    HStack(spacing: 12) {
                        Button("Show in Finder") { _ = Actions.showInFinder(c.path) }
                        Button("Scan this folder") { scanFolder(c.path) }
                    }
                    .buttonStyle(.link)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if let m = c.measurement {
                    Text(SizeText.string(m.size)).monospacedDigit()
                    Text(SmartCleanCopy.lastUsed(m.newest)).secondaryText()
                } else {
                    Text("size unknown").secondaryText()
                }
            }
        }
        .font(.body)
        .padding(.vertical, 6)
        .help(c.path)
        .contextMenu {
            Button("Show in Finder") { _ = Actions.showInFinder(c.path) }
            Button("Open in Terminal") { _ = Actions.openInTerminal(c.path) }
            Button("Quick Look") { QuickLookBridge.toggle(path: c.path) }
            Divider()
            Button("Never clean this") { controller.neverClean(c.path) }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var checkbox: some View {
        if SmartCleanController.isSelectable(candidate) {
            Toggle(candidate.displayName, isOn: Binding(
                get: { controller.selected.contains(candidate.path) },
                set: { on in
                    if on { controller.selected.insert(candidate.path) } else { controller.selected.remove(candidate.path) }
                }))
                .toggleStyle(.checkbox)
                .labelsHidden()
        } else {
            // Info and size-unknown rows can't be ticked; keep the columns aligned.
            Toggle(candidate.displayName, isOn: .constant(false))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(true)
                .opacity(candidate.tier == .info ? 0 : 1)
                .accessibilityHidden(candidate.tier == .info)
        }
    }
}

/// A section's tri-state checkbox: all, some or none of its tickable rows.
struct TriStateBox: View {
    let state: NSControl.StateValue
    let label: String
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: state == .on ? "checkmark.square.fill" : state == .mixed ? "minus.square.fill" : "square")
                .font(.title3)
                .foregroundStyle(state == .off ? Color.secondary : Color.accentColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(state == .on ? "all selected" : state == .mixed ? "some selected" : "none selected")
    }
}

/// The collapsed "Skipped (n)" list: what was found but not offered, and why.
struct SkippedSection: View {
    let skipped: [SkippedItem]
    private let expanded = State(initialValue: false)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.wrappedValue.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .frame(width: 12)
                    Text("Skipped (\(skipped.count))").font(.headline)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded.wrappedValue ? "expanded" : "collapsed")
            if expanded.wrappedValue {
                ForEach(Array(skipped.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text((item.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle).help(item.path)
                        Spacer(minLength: 8)
                        reason(item.reason)
                    }
                    .font(.body)
                    .padding(.vertical, 4)
                    .padding(.leading, 18)
                }
            }
        }
    }

    @ViewBuilder
    private func reason(_ r: SkipReason) -> some View {
        let text = SmartCleanCopy.skipReason(r)
        if r == .noAccess {
            Link(text, destination: SmartCleanCopy.fullDiskAccessURL)
        } else {
            Text(text).secondaryText().lineLimit(1).truncationMode(.middle)
        }
    }
}
