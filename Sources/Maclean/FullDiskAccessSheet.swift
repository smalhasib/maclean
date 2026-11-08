import AppKit
import SwiftUI

/// The sheet over the start screen (spec §3, mockup A): what's hidden, three
/// steps, and a way into System Settings; after the grant, a Relaunch button.
struct FullDiskAccessSheet: View {
    let granted: Bool
    /// Why Relaunch didn't happen (a delete is running).
    let refusal: String?
    let onContinue: () -> Void
    let onDismissGranted: () -> Void
    let onRelaunch: () -> Void

    private static let steps = [
        "Open System Settings › Privacy & Security › Full Disk Access",
        "Turn on Maclean",
        "Click Relaunch when you come back",
    ]

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: granted ? "lock.open.fill" : "lock.fill")
                .font(.system(size: 34))
                .foregroundStyle(granted ? Color.green : Color.accentColor)
                .accessibilityHidden(true)
            Text(granted ? "Full Disk Access is on" : "Give Maclean Full Disk Access")
                .font(.title2.weight(.semibold))
            if granted {
                Text("Relaunch Maclean to use it.")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let refusal {
                    Text(refusal).secondaryText()
                }
                Button("Relaunch", action: onRelaunch)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                Button("Later", action: onDismissGranted)
                    .buttonStyle(.link)
            } else {
                Text("Without it, macOS hides Mail, Messages, Photos, parts of Library and other apps' data. Scans miss them and totals come out low.")
                    .multilineTextAlignment(.center)
                    .secondaryText()
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.body.weight(.semibold))
                                .frame(width: 22, height: 22)
                                .background(Color.accentColor.opacity(0.15), in: Circle())
                            Text(step).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                Button {
                    NSWorkspace.shared.open(FullDiskAccess.settingsURL)
                } label: {
                    Text("Open System Settings").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                Button("Continue without Full Disk Access", action: onContinue)
                    .buttonStyle(.link)
            }
        }
        .font(.body)
        .padding(28)
        .frame(width: 420)
    }
}
