import MacleanCore
import SwiftUI

/// The update sheet (spec §5.2, `password-and-update-v3.html`): the new
/// version, what's new as plain text, the automatic-check box, and Skip This
/// Version / Later / Install and Relaunch on one line. Also shows the manual
/// check's progress and result, the download and the install.
struct UpdateSheet: View {
    let controller: UpdateController
    @AppStorage(UpdateController.automaticKey) private var automatic = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(20)
        .frame(width: 440, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        switch controller.state {
        case .available(let release):
            available(release)
        case .checking:
            status("Checking for updates…", detail: nil, progress: nil) {
                Button("Cancel", action: controller.cancel).keyboardShortcut(.cancelAction)
            }
        case .upToDate:
            status("You're up to date", detail: "Maclean \(controller.currentVersion) is the newest version.",
                   progress: nil) {
                Button("OK", action: controller.later).keyboardShortcut(.defaultAction)
            }
        case .failed(let message):
            status("Maclean couldn't update", detail: message, progress: nil) {
                Button("OK", action: controller.later).keyboardShortcut(.defaultAction)
            }
        case .downloading(let fraction):
            status("Downloading Maclean \(versionText)…", detail: nil, progress: fraction) {
                Button("Cancel", action: controller.cancel).keyboardShortcut(.cancelAction)
            }
        case .installing:
            status("Installing Maclean \(versionText)…", detail: "Maclean relaunches when it's done.",
                   progress: nil) { EmptyView() }
        case .idle:
            EmptyView()
        }
    }

    private var versionText: String { controller.release.map { "\($0.version)" } ?? "" }

    @ViewBuilder private func available(_ release: ReleaseInfo) -> some View {
        Text("Maclean \(release.version.description) is available")
            .font(.headline)
        Text("You have \(controller.currentVersion)")
            .font(.callout)
            .secondaryText()
        VStack(alignment: .leading, spacing: 4) {
            Text("What's new").font(.callout.weight(.semibold))
            ScrollView {
                // Verbatim: the release body is plain text, markdown symbols and all.
                Text(verbatim: release.notes.isEmpty ? "No release notes." : release.notes)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
        }
        .padding(8)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
        .fixedSize(horizontal: false, vertical: true)
        actionDetail
        Toggle("Check for updates automatically", isOn: $automatic)
            .font(.callout)
        if let notice = controller.notice {
            Label(notice, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        }
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button("Skip This Version", action: controller.skip).fixedSize()
            Button("Later", action: controller.later).fixedSize().keyboardShortcut(.cancelAction)
            primaryButton.fixedSize().keyboardShortcut(.defaultAction)
        }
        .padding(.top, 4)
    }

    @ViewBuilder private var actionDetail: some View {
        switch controller.action {
        case .brew:
            Text("Maclean was installed with Homebrew. Update it in Terminal:")
                .font(.callout)
            Text(verbatim: UpdateController.brewCommand)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
        case .download:
            Text("Download the update from GitHub and replace Maclean with it.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        case .install, .installWithPassword:
            EmptyView()
        }
    }

    @ViewBuilder private var primaryButton: some View {
        switch controller.action {
        case .brew:
            Button("Copy Command", action: controller.copyBrewCommand)
        case .download:
            Button("Download") { Task { await controller.install() } }
        case .install, .installWithPassword:
            Button("Install and Relaunch") { Task { await controller.install() } }
        }
    }

    @ViewBuilder private func status<Buttons: View>(
        _ title: String, detail: String?, progress: Double?, @ViewBuilder buttons: () -> Buttons
    ) -> some View {
        Text(title).font(.headline)
        if let detail {
            Text(detail)
                .font(.callout)
                .secondaryText()
                .fixedSize(horizontal: false, vertical: true)
        }
        if let progress {
            ProgressView(value: progress)
        } else if controller.state == .checking || controller.state == .installing {
            ProgressView().progressViewStyle(.linear)
        }
        HStack {
            Spacer(minLength: 0)
            buttons().fixedSize()
        }
        .padding(.top, 4)
    }
}
