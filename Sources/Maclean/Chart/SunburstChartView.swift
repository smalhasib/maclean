import AppKit
import MacleanCore
import MacleanKit
import QuartzCore
import SwiftUI

/// Draws `SunburstLayout.segments` as rings around a centre disc.
///
/// - The resting chart is rendered once into a bitmap (per layout, size,
///   appearance and contrast setting) that becomes the backing layer's
///   `contents`. Hover never redraws it: the highlighted segment is a
///   `CAShapeLayer` on top whose path is set on hover (faded in over 0.1 s by
///   Core Animation, instantly with Reduce Motion) and committed at once,
///   before the side list is told about the hover.
/// - Navigation animates over 0.35 s (ease-in-out) on the view's display link:
///   drilling in, the new layout starts where its root sat in the old one
///   (angles and ring scaled into that slice) and sweeps out to full size while
///   the old layout fades; drilling out is the reverse. Unrelated jumps, and
///   all transitions with Reduce Motion on, crossfade. Each frame is rendered
///   into a reused bitmap and set as the layer's contents.
/// - Segments are batched into one path per colour for drawing.
/// - Accessibility: one group element ("Disk map of <folder>") whose children
///   are the ring-1 segments, each a pressable element framed on its segment.
/// - Keyboard focus is shown only when it came from the keyboard: an accent
///   outline on the keyboard-current segment (or a thin ring hugging the
///   chart when nothing is selected), never the system's full focus ring.
final class SunburstChartView: NSView {
    var onHover: ((Segment?) -> Void)?
    var onClick: ((Segment, NSEvent.ModifierFlags) -> Void)?
    var onMenu: ((Segment) -> NSMenu?)?
    /// Pinch: true for pinch-open (enter), false for pinch-close (enclosing folder).
    var onPinch: ((Bool) -> Void)?
    /// Swipe: true for back, false for forward.
    var onSwipe: ((Bool) -> Void)?
    /// (can go back, can go forward), bounding the swipe.
    var canSwipe: (() -> (Bool, Bool))?
    var onCentreClick: (() -> Void)?
    var onFirstFrame: (() -> Void)?
    /// Tab (false) or Shift-Tab (true) out of the chart.
    var onTabOut: ((Bool) -> Void)?
    /// The chart took keyboard focus (or was clicked).
    var onFocus: (() -> Void)?
    /// After a navigation with keyboard focus: pick a keyboard-current segment.
    var onNeedsKeyboardSelection: (() -> Void)?
    /// VoiceOver label of a segment: "<name>, <kind>, <size>".
    var segmentLabel: ((Segment) -> String)?

    static let animationDuration: TimeInterval = 0.35
    static let crossfadeDuration: TimeInterval = 0.25
    static let highlightFade: TimeInterval = 0.1
    static let padding: CGFloat = 24

    var chartLayout: SunburstLayout?
    var generation = -1
    var title = ""
    var subtitle = ""
    var canGoUp = false

    var hoverIndex: Int?
    var externalIndex: Int?
    var selectedIndex: Int?
    /// Whether focus arrived (or was last used) from the keyboard, not a click.
    var keyboardFocus = false
    /// Ring-1 accessibility children, rebuilt after a layout or size change.
    var accessibilityElements: [SegmentElement]?
    /// The same elements by segment index; read by the nonisolated hit-test (on the main thread).
    nonisolated(unsafe) var elementsByIndex: [Int: SegmentElement] = [:]
    // Removed in deinit, which isn't main-actor isolated.
    nonisolated(unsafe) var windowObservers: [any NSObjectProtocol] = []
    /// The segment index the highlight layer currently shows.
    var shownHighlight: Int?
    var centreHovered = false
    var pressedHit: Hit?
    /// Magnification accumulated in the current pinch; nil once it fired.
    var pinch: CGFloat? = 0
    static let pinchThreshold: CGFloat = 0.12

    struct Transition {
        enum Kind {
            /// The new root sat at `ring` / `a0..<a1` of the old layout.
            case zoomIn(ring: Int, a0: Double, a1: Double)
            /// The old root sits at `ring` / `a0..<a1` of the new layout.
            case zoomOut(ring: Int, a0: Double, a1: Double)
            case crossfade
        }
        let kind: Kind
        let from: SunburstLayout
        let fromTitle: String
        let fromSubtitle: String
        let start: TimeInterval
        let duration: TimeInterval
        var frames = 0
        var lastFrame: TimeInterval = 0
    }
    var transition: Transition?
    var link: CADisplayLink?

    var cache: CGImage?
    var cacheValid = false
    /// Whether the layer's contents are the resting `cache` (not an animation frame).
    var showingCache = false
    var frameContext: CGContext?
    var firstFrameDone = false
    var trackingArea: NSTrackingArea?
    var colorCache: [ColorKey: CGColor] = [:]
    let highlightLayer = CAShapeLayer()
    let centreLayer = CAShapeLayer()
    let focusLayer = CAShapeLayer()
    // Read in deinit, which isn't main-actor isolated; written once in init.
    nonisolated(unsafe) private var accessibilityObserver: (any NSObjectProtocol)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.contentsGravity = .resize
        focusRingType = .none   // the focus is drawn on a segment instead (focusLayer)
        for sub in [centreLayer, highlightLayer, focusLayer] {
            sub.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
            sub.lineWidth = 1
            layer?.addSublayer(sub)
        }
        focusLayer.fillColor = nil
        focusLayer.lineJoin = .round
        focusLayer.isHidden = true
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Increase Contrast: palette, gaps, label colours and outlines all change.
                guard let self else { return }
                self.invalidateCache()
                self.shownHighlight = nil
                self.updateHighlightLayer(animated: false)
                self.invalidateAccessibility()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Keys while the chart has focus (arrow traversal, Return, Space);
    /// returns false for keys it doesn't handle.
    var onKey: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightLayer.frame = bounds
        centreLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers = []
        if let window {
            // The focus outline shows only in the key window.
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateFocusLayer() }
                })
            }
        } else {
            stopLink()
            transition = nil
        }
    }

    // MARK: Content

    func setContent(layout new: SunburstLayout, generation newGeneration: Int, title: String, subtitle: String,
                    canGoUp: Bool, animated: Bool) {
        self.canGoUp = canGoUp
        guard newGeneration != generation else { return }
        let old = chartLayout
        let oldTitle = self.title, oldSubtitle = self.subtitle
        chartLayout = new
        generation = newGeneration
        self.title = title
        self.subtitle = subtitle
        hoverIndex = nil
        externalIndex = nil
        selectedIndex = nil
        invalidateCache()
        invalidateAccessibility()

        if animated, let old, window != nil, !bounds.isEmpty {
            startTransition(from: old, to: new, fromTitle: oldTitle, fromSubtitle: oldSubtitle)
        }
        updateHighlightLayer(animated: false)
        // Re-evaluate what's under a resting pointer once the new chart is in.
        if transition == nil { refreshHoverFromMouse() }
    }

    /// A list-row hover: the index of the segment to highlight (nil for none).
    func setExternalHighlight(index: Int?) {
        guard index != externalIndex else { return }
        externalIndex = index
        if hoverIndex == nil { updateHighlightLayer(animated: true) }
    }

    // MARK: Geometry

    struct Geometry {
        let center: CGPoint
        let outer: CGFloat
        let inner: CGFloat
        let ringWidth: CGFloat
        var discRadius: CGFloat { inner - 3 }

        func innerRadius(ringPosition p: CGFloat) -> CGFloat { inner + (p - 1) * ringWidth }
    }

    var geometry: Geometry {
        let side = max(min(bounds.width, bounds.height) - 2 * Self.padding, 80)
        let outer = side / 2
        let inner = max(outer * 0.27, 40)
        return Geometry(center: CGPoint(x: bounds.midX, y: bounds.midY), outer: outer, inner: inner,
                        ringWidth: max((outer - inner) / CGFloat(SunburstLayout.maxRings), 1))
    }

    enum Hit: Equatable { case segment(Int), centre, none }

    func hit(at point: CGPoint) -> Hit {
        guard let chartLayout else { return .none }
        let g = geometry
        let dx = Double(point.x - g.center.x), dy = Double(point.y - g.center.y)
        let r = (dx * dx + dy * dy).squareRoot()
        if r <= Double(g.discRadius) { return .centre }
        let angle = atan2(dx, -dy)   // 0 at 12 o'clock, clockwise (flipped view)
        guard let i = chartLayout.segmentIndex(atRadius: r, angle: angle, innerRadius: Double(g.inner),
                                          ringWidth: Double(g.ringWidth)) else { return .none }
        return .segment(i)
    }
}
