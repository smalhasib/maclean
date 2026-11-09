import CoreGraphics
import Foundation

/// The walkthrough of a result window for someone seeing the chart for the first time. It shows
/// itself once, on the first result ever opened, and Help › Show Graph Guide plays it again.
enum GraphGuide {
    /// Set as soon as the guide first shows, so closing the window half way doesn't bring it back.
    static let seenKey = "GraphGuideSeen"

    /// What a step points at. `ring` and `centre` are parts of the chart, found from its frame.
    enum Focus: Hashable { case chart, ring, centre, breadcrumbs, list, collector }

    struct Step: Equatable {
        let focus: Focus
        let title: String
        let body: String
    }

    static let steps: [Step] = [
        Step(focus: .chart, title: "Your disk, drawn as rings",
             body: "Every segment is a file or a folder, and the wider it is, the more space it takes. "
                 + "Folders inside folders sit in the outer rings."),
        Step(focus: .ring, title: "Hover to look, click to go in",
             body: "Hover a segment to see its name and size in the list. "
                 + "Click a folder's segment to go inside it."),
        Step(focus: .centre, title: "The centre is where you are",
             body: "It shows the folder you're in and its total size. Click it to go back up one level."),
        Step(focus: .breadcrumbs, title: "Jump back anywhere",
             body: "The path along the top shows where you are. Click any name in it to jump straight back, "
                 + "or Disks for the disk list."),
        Step(focus: .list, title: "The biggest things, ranked",
             body: "The list shows what's inside, largest first. Hover a row to preview the file "
                 + "(the eye) or collect it (the tray)."),
        Step(focus: .collector, title: "Collect, then delete",
             body: "Drag items here, or press ⌘⌫, to collect them. You see the space you'll get back, "
                 + "and nothing is deleted until you confirm."),
    ]

    /// Padding around the chart, as in `SunburstChartView` (the test checks they agree).
    static let chartPadding: CGFloat = 24

    struct ChartGeometry: Equatable {
        let center: CGPoint
        /// Outer edge of the rings.
        let outer: CGFloat
        /// Inner edge of the rings.
        let inner: CGFloat
        /// The centre disc.
        let disc: CGFloat
    }

    /// Where the chart draws its rings within `frame`: the same rules as `SunburstChartView.geometry`.
    static func chartGeometry(in frame: CGRect) -> ChartGeometry {
        let side = max(min(frame.width, frame.height) - 2 * chartPadding, 80)
        let outer = side / 2
        let inner = max(outer * 0.27, 40)
        return ChartGeometry(center: CGPoint(x: frame.midX, y: frame.midY), outer: outer, inner: inner, disc: inner - 3)
    }
}
