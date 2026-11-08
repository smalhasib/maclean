import SwiftUI

/// Settings (spec §5.5): a General tab with the window-mode, Trash and
/// administrator-read toggles, and the Smart Clean tab.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .frame(width: 440)
                .tabItem { Label("General", systemImage: "gearshape") }
            SmartCleanSettings()
                .frame(width: 440, height: 560)
                .tabItem { Label("Smart Clean", systemImage: "sparkles") }
        }
    }
}

private struct GeneralSettings: View {
    @AppStorage(WindowRouter.ownWindowKey) private var ownWindow = false
    @AppStorage(DeleteController.trashKey) private var moveToTrash = false
    @AppStorage(AdminBatcher.askKey) private var askForAdminReads = true

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
            Toggle("Ask for the administrator password to read restricted folders", isOn: $askForAdminReads)
            Text("Asked once after a scan finds folders only an administrator can open, and when Smart Clean finds system items it can't measure.")
                .font(.callout)
                .secondaryText()
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}
