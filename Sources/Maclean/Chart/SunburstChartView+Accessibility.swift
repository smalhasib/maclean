import AppKit
import MacleanCore
import MacleanKit
import QuartzCore
import SwiftUI

extension SunburstChartView {
    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Disk map of \(subtitle)" }

    override func accessibilityChildren() -> [Any]? {
        if let accessibilityElements { return accessibilityElements }
        guard let chartLayout else { return [] }
        let g = geometry
        var elements: [SegmentElement] = []
        for (i, s) in chartLayout.segments.enumerated() where s.ring == 1 {
            let path = CGMutablePath()
            addSegment(to: path, geometry: g, ringPosition: 1, a0: s.startAngle, a1: s.endAngle, gap: gap)
            // "smaller objects" does nothing on click: a static element, no AXPress.
            let element: SegmentElement
            if s.node == nil {
                element = SegmentElement()
                element.setAccessibilityRole(.staticText)
            } else {
                let pressable = PressableSegmentElement()
                pressable.setAccessibilityRole(.button)
                // Presses on an element held from an older layout are ignored.
                let layoutGeneration = generation, node = s.node
                pressable.press = { [weak self] in
                    self?.pressSegment(i, node: node, generation: layoutGeneration) ?? false
                }
                element = pressable
            }
            element.setAccessibilityLabel(segmentLabel?(s) ?? "")
            element.setAccessibilityParent(self)
            // Parent space is bottom-left based even for a flipped view.
            var box = path.boundingBoxOfPath
            box.origin.y = bounds.height - box.maxY
            element.setAccessibilityFrameInParentSpace(box)
            element.index = i
            element.chart = self
            elements.append(element)
        }
        accessibilityElements = elements
        elementsByIndex = Dictionary(uniqueKeysWithValues: elements.map { ($0.index, $0) })
        return elements
    }

    /// VoiceOver's pointer hit-test: the ring-1 segment under `point` (screen
    /// coordinates), else the chart. AppKit may ask the chart or any child whose
    /// (rectangular) frame holds the point, so both answer from the real geometry.
    /// It calls on the main thread, but the SDK declares it nonisolated.
    override nonisolated func accessibilityHitTest(_ point: NSPoint) -> Any? {
        accessibilityElement(atScreen: point)
    }

    nonisolated fileprivate func accessibilityElement(atScreen point: NSPoint) -> Any? {
        let index: Int? = MainActor.assumeIsolated {
            guard let window else { return nil }
            _ = accessibilityChildren()   // builds `elementsByIndex`
            if case .segment(let i) = hit(at: convert(window.convertPoint(fromScreen: point), from: nil)) { return i }
            return nil
        }
        return index.flatMap { elementsByIndex[$0] } ?? self
    }

    /// VoiceOver's press on a ring-1 segment: the same as a plain click.
    func pressSegment(_ i: Int, node: NodeID?, generation pressed: Int) -> Bool {
        guard pressed == generation, transition == nil, let chartLayout, i < chartLayout.segments.count,
              chartLayout.segments[i].node == node else { return false }
        onClick?(chartLayout.segments[i], [])
        return true
    }

    func invalidateAccessibility() {
        guard accessibilityElements != nil else { return }
        accessibilityElements = nil
        elementsByIndex = [:]
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }
}

/// A ring-1 segment as an accessibility element.
class SegmentElement: NSAccessibilityElement {
    var index = 0
    nonisolated(unsafe) weak var chart: SunburstChartView?

    /// A segment's frame is its bounding box, which overlaps its neighbours';
    /// the chart resolves the point against the real ring geometry.
    override nonisolated func accessibilityHitTest(_ point: NSPoint) -> Any? {
        chart?.accessibilityElement(atScreen: point) ?? self
    }
}

/// A ring-1 file or folder segment; VoiceOver's press acts as a click.
private final class PressableSegmentElement: SegmentElement {
    var press: (() -> Bool)?

    override func accessibilityPerformPress() -> Bool { press?() ?? false }
}
