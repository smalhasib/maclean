import MacleanCore
import MacleanKit
import SwiftUI

/// The sheet shown after a delete run: what was freed, then (each only when
/// non-empty) the items changed since the scan with Delete Anyway / Keep,
/// the items that couldn't be deleted with their reasons, and the items
/// already gone.
///
/// Shared by the collector and Smart Clean: `resolveChanged` is the collector's
/// Delete Anyway / Keep; without it (Smart Clean) changed items are only listed,
/// since the next check offers them again.
struct DeleteSummaryView: View {
    let report: DeleteReport
    let title: String
    var changedTitle = "Changed since the scan"
    var resolveChanged: (([String], Bool) -> Void)?
    let done: () -> Void

    /// "Freed 1.2 GB" / "Moved 1.2 GB to the Trash".
    static func title(freed: Int64, mode: DeleteMode) -> String {
        let size = SizeText.string(freed)
        return mode == .trash ? "Moved \(size) to the Trash" : "Freed \(size)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 12)
            if hasSections {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        changedSection
                        failedSection
                        goneSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }
                .frame(maxHeight: 360)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { done() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var hasSections: Bool {
        !report.changed.isEmpty || !report.failed.isEmpty || !report.alreadyGone.isEmpty
    }

    @ViewBuilder
    private var changedSection: some View {
        if !report.changed.isEmpty {
            let paths = report.changed.keys.sorted()
            section(changedTitle) {
                if paths.count > 1, let resolveChanged {
                    HStack(spacing: 8) {
                        Button("Delete All Anyway") { resolveChanged(paths, true) }
                        Button("Keep All") { resolveChanged(paths, false) }
                    }
                }
            } rows: {
                ForEach(paths, id: \.self) { path in
                    let change = report.changed[path]!
                    HStack(spacing: 8) {
                        item(path, detail: "Now \(SizeText.string(change.size)), "
                             + (change.files == 1 ? "1 file" : "\(change.files.formatted()) files"))
                        Spacer(minLength: 8)
                        if let resolveChanged {
                            Button("Delete Anyway") { resolveChanged([path], true) }
                            Button("Keep") { resolveChanged([path], false) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var failedSection: some View {
        if !report.failed.isEmpty {
            section("Couldn't delete") {
                EmptyView()
            } rows: {
                ForEach(report.failed.keys.sorted(), id: \.self) { path in
                    item(path, detail: report.failed[path]!)
                }
            }
        }
    }

    @ViewBuilder
    private var goneSection: some View {
        if !report.alreadyGone.isEmpty {
            section("Already gone") {
                EmptyView()
            } rows: {
                ForEach(report.alreadyGone.sorted(), id: \.self) { path in
                    item(path, detail: nil)
                }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder actions: () -> some View,
                         @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer(minLength: 8)
                actions()
            }
            VStack(alignment: .leading, spacing: 8) { rows() }
        }
    }

    /// An item's name (middle-truncated, full path in the tooltip) and an
    /// optional secondary line.
    private func item(_ path: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text((path as NSString).lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .secondaryText()
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(path)
        .accessibilityElement(children: .combine)
    }
}
