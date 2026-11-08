import AppKit
import MacleanCore
import MacleanKit
import SwiftUI

/// The Smart Clean review sheet (spec §5.2): selected and found sizes, Check
/// again, Clean; category sections of rows; the Skipped list. Clean confirms in
/// an alert, shows progress with Stop, then the shared summary sheet.
struct SmartCleanReviewView: View {
    let controller: SmartCleanController
    let close: () -> Void
    @AppStorage(DeleteController.trashKey) private var moveToTrash = false
    // `State` used as a type: the `@State` macro's plugin ships only with Xcode.
    private let expanded = State(initialValue: Set<CleanRule.Category>())

    private static let systemCategories: Set<CleanRule.Category> = [.systemLogs, .systemCaches, .systemServices]

    var body: some View {
        VStack(spacing: 0) {
            header
            Separator()
            ZStack {
                list
                if case .cleaning(let done, let total) = controller.phase { progress(done: done, total: total) }
            }
        }
        .frame(minWidth: 520, idealWidth: 640, minHeight: 380, idealHeight: 560)
        .background(SheetQuickLook())
        .alert(alertCopy.title, isPresented: Binding(get: { controller.phase == .confirming },
                                                     set: { if !$0 { controller.cancelClean() } })) {
            Button("Clean") { Task { await controller.clean() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(alertCopy.message)
        }
        .sheet(isPresented: Binding(get: { if case .summary = controller.phase { true } else { false } },
                                    set: { if !$0 { controller.dismissSummary() } })) {
            if case .summary(let report) = controller.phase {
                DeleteSummaryView(report: report,
                                  title: DeleteSummaryView.title(freed: report.freed, mode: controller.lastMode),
                                  changedTitle: "Changed since the check",
                                  done: { controller.dismissSummary() })
                    .interactiveDismissDisabled()
            }
        }
    }

    private var alertCopy: (title: String, message: String) {
        let count = controller.selected.count
        return SmartCleanCopy.alert(count: count, size: controller.selectedSize,
                                    mode: moveToTrash ? .trash : .permanent, needsAdmin: controller.needsAdmin,
                                    includesTrash: controller.selectedIncludesTrash)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Button("Close", action: close)
                .keyboardShortcut(.cancelAction)
                .disabled(isBusy)
            Spacer(minLength: 8)
            Text("\(SizeText.string(controller.selectedSize)) selected of \(SizeText.string(controller.foundSize)) found")
                .font(.headline)
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 8)
            if controller.isChecking { ProgressView().controlSize(.small) }
            Button("Check again") { controller.check() }
                .disabled(isBusy)
            Button("Clean") { controller.requestClean() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(controller.selected.isEmpty || controller.phase != .ready)
        }
        .font(.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Cleaning, confirming or measuring: the sheet can't be left or re-checked.
    private var isBusy: Bool {
        switch controller.phase {
        case .confirming, .cleaning: true
        default: controller.awaitingAdmin
        }
    }

    // MARK: List

    private var candidates: [CleanCandidate] { controller.report?.candidates ?? [] }

    private func categories(_ wanted: (CleanRule.Category) -> Bool) -> [CleanRule.Category] {
        CleanRule.Category.allCases.filter { c in wanted(c) && candidates.contains { $0.category == c } }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if candidates.isEmpty {
                    Text(controller.isChecking ? SmartCleanCopy.checking : SmartCleanCopy.nothing)
                        .font(.body).secondaryText()
                        .frame(maxWidth: .infinity).padding(.top, 40)
                }
                ForEach(categories { !Self.systemCategories.contains($0) }, id: \.self) { section($0) }
                let system = categories { Self.systemCategories.contains($0) }
                if !system.isEmpty { systemGroup(system) }
                if let skipped = controller.report?.skipped, !skipped.isEmpty {
                    SkippedSection(skipped: skipped).padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .disabled(isBusy)
    }

    /// The system categories, with the one administrator-rights measure for their unknown sizes.
    private func systemGroup(_ system: [CleanRule.Category]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("System").font(.headline).secondaryText()
                Spacer(minLength: 8)
                if candidates.contains(where: { $0.requiresAdmin && $0.measurement == nil }) {
                    Button("Measure with administrator rights") { Task { await controller.measureWithAdmin() } }
                        .disabled(controller.phase != .ready || controller.awaitingAdmin)
                }
            }
            .padding(.top, 14)
            .padding(.bottom, 4)
            ForEach(system, id: \.self) { section($0) }
        }
    }

    private func section(_ category: CleanRule.Category) -> some View {
        let rows = candidates.filter { $0.category == category }.sorted { ($0.measurement?.size ?? -1) > ($1.measurement?.size ?? -1) }
        let paths = rows.filter(SmartCleanController.isSelectable).map(\.path)
        let total = rows.filter { $0.tier != .info }.reduce(Int64(0)) { $0 + ($1.measurement?.size ?? 0) }
        let open = expanded.wrappedValue.contains(category)
        let name = SmartCleanCopy.name(category)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if paths.isEmpty {
                    Color.clear.frame(width: 18, height: 18)
                } else {
                    TriStateBox(state: CategoryState.tri(paths, selected: controller.selected), label: name) {
                        if CategoryState.tri(paths, selected: controller.selected) == .on {
                            controller.selected.subtract(paths)
                        } else {
                            controller.selected.formUnion(paths)
                        }
                    }
                }
                Button {
                    if open { expanded.wrappedValue.remove(category) } else { expanded.wrappedValue.insert(category) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: open ? "chevron.down" : "chevron.right").frame(width: 12)
                        Text(name).font(.headline)
                        Spacer(minLength: 8)
                        if total > 0 { Text(SizeText.string(total)).monospacedDigit().secondaryText() }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(open ? "expanded" : "collapsed")
            }
            .font(.body)
            .padding(.vertical, 8)
            if open { sectionRows(rows) }
            Separator()
        }
    }

    /// Rows, grouped under their project when they have one (Project leftovers).
    @ViewBuilder
    private func sectionRows(_ rows: [CleanCandidate]) -> some View {
        let groups = Dictionary(grouping: rows) { $0.group ?? "" }
        let ordered = groups.keys.sorted { a, b in
            if a.isEmpty != b.isEmpty { return a.isEmpty }
            let sa = groups[a]!.reduce(Int64(0)) { $0 + ($1.measurement?.size ?? 0) }
            let sb = groups[b]!.reduce(Int64(0)) { $0 + ($1.measurement?.size ?? 0) }
            return sa != sb ? sa > sb : a < b
        }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ordered, id: \.self) { group in
                if !group.isEmpty {
                    Text(group).font(.body.weight(.semibold)).secondaryText().padding(.top, 6).padding(.leading, 28)
                }
                ForEach(groups[group]!) { row in
                    SmartCleanRow(controller: controller, candidate: row, scanFolder: scan)
                        .padding(.leading, 28)
                }
            }
        }
    }

    private func scan(_ path: String) {
        controller.registry?.startScan(path: path)
        close()
    }

    // MARK: Progress

    private func progress(done: Int, total: Int) -> some View {
        VStack(spacing: 12) {
            Text(controller.awaitingAdmin ? "Waiting for your administrator password…" : "Deleting \(done) of \(total)…")
                .font(.headline)
                .monospacedDigit()
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .frame(width: 280)
            Button("Stop") { controller.stop() }
                .disabled(controller.awaitingAdmin)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
}
