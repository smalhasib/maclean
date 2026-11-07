import SwiftUI

/// Settings (spec §5.5): a General tab with the window-mode toggle. Other
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

    var body: some View {
        Form {
            Toggle("Open each scan in its own window", isOn: $ownWindow)
            Text("Applies to the next window opened. Off: the start screen and a result share one window.")
                .font(.callout)
                .secondaryText()
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}
