import AppKit
import MacleanCore
import MacleanKit
import SwiftUI

/// The collector bar at the bottom of a result window.
///
/// - Empty: a dashed circle and a hint.
/// - With items: a ring proportional to the collected share of the scan
///   with the total inside, "<size> collected", and a red Delete button.
///   Clicking the circle (or Return / Space on it, see `ResultResponder`)
///   toggles the collector panel.
/// - A drop target for Maclean items and Finder files.
/// - Refusals show in a popover on the circle, dismissed after 4 s or on
///   click, and are announced to VoiceOver.
struct CollectorBar: View {
    let model: ResultViewModel
    // `State` used as a type: the `@State` macro's plugin ships only with Xcode.
    private let targeted = State(initialValue: false)
    @Environment(\.controlActiveState) private var activeState

    init(model: ResultViewModel) {
        self.model = model
    }

    static let height: CGFloat = 56

    var body: some View {
        let view = model.view
        let count = view.collected.count
        HStack(spacing: 12) {
            circle(view: view, count: count)
            if count == 0 {
                Text("Drag files here to collect them")
                    .secondaryText()
                    .lineLimit(1)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            } else {
                Text("\(SizeText.string(view.collectedSize)) collected")
                    .monospacedDigit()
                    .lineLimit(1)
                    .accessibilityHidden(true)
                Spacer(minLength: 8)
                // Task 7 wires this to the delete countdown.
                Button("Delete") {}
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(true)
                    .help("Delete the collected items")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Self.height)
        .background(targeted.wrappedValue ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onDrop(of: [.macleanNode, .fileURL],
                delegate: CollectorDropDelegate(model: model, targeted: targeted.projectedValue))
        .onChange(of: model.collectorRefusal?.id) { _, id in
            guard id != nil, let text = model.collectorRefusal?.text else { return }
            NSAccessibility.post(element: NSApp.mainWindow ?? NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: text,
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    @ViewBuilder
    private func circle(view: TreeView, count: Int) -> some View {
        Group {
            if count == 0 {
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    .foregroundStyle(targeted.wrappedValue ? AnyShapeStyle(Color.accentColor)
                                                           : AnyShapeStyle(.tertiary))
                    .frame(width: 26, height: 26)
                    .frame(width: 46, height: 46)
                    .accessibilityElement()
                    .accessibilityLabel("Collector, empty")
                    .accessibilityHint("Drag files here to collect them")
            } else {
                let total = view.tree.size(of: view.tree.root)
                let fraction = total > 0 ? min(Double(view.collectedSize) / Double(total), 1) : 0
                Button {
                    model.toolbarFocus = nil
                    model.collectorPanelOpen.toggle()
                } label: {
                    CollectorRing(fraction: fraction, total: view.collectedSize)
                }
                .buttonStyle(.plain)
                .focusOutline(model.toolbarFocus == .collector && activeState == .key)
                .help(model.collectorPanelOpen ? "Hide collected items" : "Show collected items")
                .accessibilityLabel("Collector, \(count == 1 ? "1 item" : "\(count.formatted()) items"), "
                                    + SizeText.spoken(view.collectedSize))
                .accessibilityValue(model.collectorPanelOpen ? "expanded" : "collapsed")
            }
        }
        .popover(isPresented: refusalShown, arrowEdge: .top) {
            if let refusal = model.collectorRefusal {
                Text(refusal.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320, alignment: .leading)
                    .padding(12)
                    .contentShape(Rectangle())
                    .onTapGesture { model.dismissCollectorRefusal() }
            }
        }
        .task(id: model.collectorRefusal?.id) {
            guard let id = model.collectorRefusal?.id else { return }
            try? await Task.sleep(for: .seconds(4))
            model.dismissCollectorRefusal(id)
        }
    }

    private var refusalShown: Binding<Bool> {
        Binding(get: { model.collectorRefusal != nil },
                set: { if !$0 { model.dismissCollectorRefusal() } })
    }
}

/// The filled collector circle: a ring for the collected share of the scan
/// and the total inside.
private struct CollectorRing: View {
    let fraction: Double
    let total: Int64
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(contrast == .increased ? 0.35 : 0.1), lineWidth: 4)
            Circle()
                // A sliver stays visible for tiny shares.
                .trim(from: 0, to: max(fraction, 0.02))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(SizeText.string(total))
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 6)
        }
        .padding(2)
        .frame(width: 46, height: 46)
        .contentShape(Circle())
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: fraction)
    }
}
