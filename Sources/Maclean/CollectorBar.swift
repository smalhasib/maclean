import SwiftUI

/// The collector's empty state (Plan 2): not interactive, accepts no drops.
struct CollectorBar: View {
    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                .foregroundStyle(.tertiary)
                .frame(width: 26, height: 26)
            Text("Drag files here to collect them")
                .secondaryText()
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .accessibilityElement(children: .combine)
    }
}
