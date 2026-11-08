import AppKit
import MacleanCore
import Observation
import SwiftUI

/// Smart Clean's lists in `UserDefaults` (spec §5.5), read fresh so changes made
/// elsewhere (Never clean this in the review) show up.
@MainActor @Observable final class SmartCleanPrefs {
    private(set) var neverClean: [String] = []
    private(set) var disabled: Set<CleanRule.Category> = []
    private(set) var roots: [String] = []
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
    }

    func reload() {
        neverClean = defaults.stringArray(forKey: SmartCleanController.neverCleanKey) ?? []
        disabled = Set((defaults.stringArray(forKey: SmartCleanController.disabledCategoriesKey) ?? [])
            .compactMap(CleanRule.Category.init(rawValue:)))
        roots = defaults.stringArray(forKey: SmartCleanController.projectRootsKey) ?? []
    }

    func removeNeverClean(_ path: String) {
        defaults.set(neverClean.filter { $0 != path }, forKey: SmartCleanController.neverCleanKey)
        reload()
    }

    func setEnabled(_ category: CleanRule.Category, _ on: Bool) {
        if on { disabled.remove(category) } else { disabled.insert(category) }
        defaults.set(disabled.map(\.rawValue).sorted(), forKey: SmartCleanController.disabledCategoriesKey)
    }

    func addRoot(_ path: String) {
        guard !roots.contains(path) else { return }
        defaults.set(roots + [path], forKey: SmartCleanController.projectRootsKey)
        reload()
    }

    func removeRoot(_ path: String) {
        defaults.set(roots.filter { $0 != path }, forKey: SmartCleanController.projectRootsKey)
        reload()
    }
}

/// Settings › Smart Clean: the launch check, one toggle per category, the
/// never-clean list and extra project search folders.
struct SmartCleanSettings: View {
    @AppStorage(SmartCleanController.checkAtLaunchKey) private var checkAtLaunch = true
    private let prefs = State(initialValue: SmartCleanPrefs())

    var body: some View {
        let prefs = prefs.wrappedValue
        Form {
            Section {
                Toggle("Check for cleanable items at launch", isOn: $checkAtLaunch)
                note("Changes below apply to the next check.")
            }
            Section("Categories") {
                ForEach(CleanRule.Category.allCases, id: \.self) { category in
                    Toggle(SmartCleanCopy.name(category), isOn: Binding(
                        get: { !prefs.disabled.contains(category) },
                        set: { prefs.setEnabled(category, $0) }))
                }
            }
            Section("Never clean") {
                if prefs.neverClean.isEmpty { note("Items you choose “Never clean this” for appear here.") }
                ForEach(prefs.neverClean, id: \.self) { path in
                    pathRow(path, label: "Remove \(path) from the never-clean list") { prefs.removeNeverClean(path) }
                }
            }
            Section("Project search folders") {
                note("Maclean looks for build folders in your common code folders. Add others here.")
                ForEach(prefs.roots, id: \.self) { path in
                    pathRow(path, label: "Remove \(path) from the search folders") { prefs.removeRoot(path) }
                }
                Button("Add…") {
                    if let url = FolderPicker.pick(prompt: "Add", message: "Choose a folder that holds your projects") {
                        prefs.addRoot(url.path)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in prefs.reload() }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.body).secondaryText().fixedSize(horizontal: false, vertical: true)
    }

    private func pathRow(_ path: String, label: String, remove: @escaping () -> Void) -> some View {
        HStack {
            Text((path as NSString).abbreviatingWithTildeInPath)
                .lineLimit(1).truncationMode(.middle).help(path)
            Spacer(minLength: 8)
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel(label)
                .help("Remove")
        }
    }
}
