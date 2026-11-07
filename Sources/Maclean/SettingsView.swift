import SwiftUI

/// Settings (spec §5.5): a General tab with the window-mode and Trash toggles. Other
/// tabs arrive with the plans that need them.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 440)
    }
}

private struct GeneralSettings: View {
    @AppStorage(WindowRouter.ownWindowKey) private var ownWindow = false
    @AppStorage(DeleteController.trashKey) private var moveToTrash = false

    var body: some View {
        Form {
            Toggle("Open each scan in its own window", isOn: $ownWindow)
            Text("Applies to the next window opened. Off: the start screen and a result share one window.")
                .font(.callout)
                .secondaryText()
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Move to Trash instead of deleting permanently", isOn: $moveToTrash)
            Text("Off: deleted items are gone for good, as in DaisyDisk.")
                .font(.callout)
                .secondaryText()
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}
