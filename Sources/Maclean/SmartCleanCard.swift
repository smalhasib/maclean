import MacleanCore
import SwiftUI

/// The start screen's Smart Clean card (spec §5.2): the cleanable total with
/// the top three categories and a Review… button; a spinner while checking;
/// "Nothing to clean right now", which fades after 3 s.
struct SmartCleanCard: View {
    let controller: SmartCleanController
    let review: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // `State` used as a type: the `@State` macro's plugin ships only with Xcode.
    private let faded = State(initialValue: false)

    var body: some View {
        content
            .task(id: controller.phase) {
                guard controller.phase == .nothingFound else {
                    faded.wrappedValue = false
                    return
                }
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.5)) { faded.wrappedValue = true }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle:
            EmptyView()
        case .checking:
            card {
                ProgressView().controlSize(.small)
                Text(SmartCleanCopy.checking)
                Spacer(minLength: 8)
            }
        case .nothingFound:
            if !faded.wrappedValue {
                card {
                    icon
                    Text(SmartCleanCopy.nothing)
                    Spacer(minLength: 8)
                }
                .transition(.opacity)
            }
        case .ready, .confirming, .cleaning, .summary:
            if let report = controller.report, !report.candidates.isEmpty {
                card {
                    icon
                    VStack(alignment: .leading, spacing: 2) {
                        if let size = SmartCleanCopy.cardSize(report) {
                            (Text(size).bold().monospacedDigit() + Text(" can be cleaned"))
                        } else {
                            Text(SmartCleanCopy.nothing)
                        }
                        let top = SmartCleanCopy.breakdown(report)
                        if !top.isEmpty {
                            Text(top).secondaryText().lineLimit(1).truncationMode(.tail).help(top)
                        }
                    }
                    Spacer(minLength: 8)
                    Button("Review…", action: review)
                }
            }
        }
    }

    private var icon: some View {
        Image(systemName: "sparkles")
            .font(.title2)
            .foregroundStyle(Color.accentColor)
            .frame(width: 32)
            .accessibilityHidden(true)
    }

    private func card(@ViewBuilder _ row: () -> some View) -> some View {
        HStack(spacing: 12) { row() }
            .font(.body)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .accessibilityElement(children: .contain)
    }
}
