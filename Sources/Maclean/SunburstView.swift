import AppKit
import MacleanCore
import MacleanKit
import QuartzCore
import SwiftUI

/// The ring chart for a result. Reads the model in `body`, so SwiftUI tracks
/// exactly the properties the chart depends on.
struct SunburstView: View {
    let model: ResultViewModel
    @Environment(\.windowRouter) private var router

    var body: some View {
        let node = model.currentNode
        // A list-row hover highlights its segment; otherwise the selection does.
        let external = model.hoverSource == .list ? (model.hovered ?? model.selected) : model.selected
        SunburstRepresentable(
            model: model, router: router, layout: model.layout, generation: model.layoutGeneration,
            title: SizeText.string(model.tree.size(of: node)), subtitle: model.name(of: node),
            canGoUp: model.tree.parent(of: node) != nil,
            listHoverIndex: external.flatMap { model.chartIndex(forListItem: $0) },
            selectedIndex: model.selected.flatMap { model.chartIndex(forListItem: $0) })
    }
}

/// `SunburstChartView` (Core Graphics in an NSView) wrapped for SwiftUI.
private struct SunburstRepresentable: NSViewRepresentable {
    let model: ResultViewModel
    let router: WindowRouter?
    let layout: SunburstLayout
    let generation: Int
    let title: String
    let subtitle: String
    let canGoUp: Bool
    let listHoverIndex: Int?
    /// The keyboard-current segment, outlined while the chart has keyboard focus.
    let selectedIndex: Int?

    func makeNSView(context: Context) -> SunburstChartView {
        let view = SunburstChartView()
        view.onHover = { [weak model] segment in
            model?.hover(segment?.node, from: .chart)
        }
        let router = self.router
        view.onClick = { [weak model] segment, flags in
            guard let model, let node = segment.node else { return }
            // ⌘-click: Show in Finder; ⌥-click a folder: Open in New Window.
            if ResultActions(model: model, router: router).modifiedClick(node, flags: flags) { return }
            if model.isDrillable(node) { model.open(node) } else { model.selected = node }
        }
        view.onMenu = { [weak model] segment in
            guard let model, let node = segment.node else { return nil }
            return ResultActions(model: model, router: router).contextMenu(for: node)
        }
        view.onPinch = { [weak model] opening in
            guard let model else { return }
            if opening {
                if let target = model.actionTarget { ResultActions(model: model, router: router).enter(target) }
            } else {
                model.goUp()
            }
        }
        view.onSwipe = { [weak model] back in
            if back { model?.back() } else { model?.forward() }
        }
        view.canSwipe = { [weak model] in (model?.history.canGoBack ?? false, model?.history.canGoForward ?? false) }
        view.onKey = { [weak model] event in
            guard let model else { return false }
            return ResultActions(model: model, router: router).handleKey(event, chart: true)
        }
        view.onCentreClick = { [weak model] in model?.goUp() }
        view.onFirstFrame = { [weak model] in model?.chartDidDrawFirstFrame() }
        view.segmentLabel = { [weak model] segment in
            guard let model else { return "" }
            guard let node = segment.node else { return "smaller objects, \(SizeText.spoken(segment.mergedSize))" }
            return model.accessibilityLabel(of: node)
        }
        apply(to: view, animated: false)
        return view
    }

    func updateNSView(_ view: SunburstChartView, context: Context) {
        apply(to: view, animated: true)
    }

    private func apply(to view: SunburstChartView, animated: Bool) {
        view.setContent(layout: layout, generation: generation, title: title, subtitle: subtitle,
                        canGoUp: canGoUp, animated: animated)
        // A list-row hover highlights its segment, or the "smaller objects"
        // segment it was merged into.
        view.setExternalHighlight(index: listHoverIndex)
        view.setSelectedIndex(selectedIndex)
    }
}

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
    /// VoiceOver label of a segment: "<name>, <kind>, <size>".
    var segmentLabel: ((Segment) -> String)?

    private static let animationDuration: TimeInterval = 0.35
    private static let crossfadeDuration: TimeInterval = 0.25
    private static let highlightFade: TimeInterval = 0.1
    private static let padding: CGFloat = 24

    private var chartLayout: SunburstLayout?
    private var generation = -1
    private var title = ""
    private var subtitle = ""
    private var canGoUp = false

    private var hoverIndex: Int?
    private var externalIndex: Int?
    private var selectedIndex: Int?
    /// Whether focus arrived (or was last used) from the keyboard, not a click.
    private var keyboardFocus = false
    /// Ring-1 accessibility children, rebuilt after a layout or size change.
    private var accessibilityElements: [SegmentElement]?
    /// The same elements by segment index; read by the nonisolated hit-test (on the main thread).
    nonisolated(unsafe) private var elementsByIndex: [Int: SegmentElement] = [:]
    // Removed in deinit, which isn't main-actor isolated.
    nonisolated(unsafe) private var windowObservers: [any NSObjectProtocol] = []
    /// The segment index the highlight layer currently shows.
    private var shownHighlight: Int?
    private var centreHovered = false
    private var pressedHit: Hit?
    /// Magnification accumulated in the current pinch; nil once it fired.
    private var pinch: CGFloat? = 0
    private static let pinchThreshold: CGFloat = 0.12

    private struct Transition {
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
    private var transition: Transition?
    private var link: CADisplayLink?

    private var cache: CGImage?
    private var cacheValid = false
    /// Whether the layer's contents are the resting `cache` (not an animation frame).
    private var showingCache = false
    private var frameContext: CGContext?
    private var firstFrameDone = false
    private var trackingArea: NSTrackingArea?
    private var colorCache: [ColorKey: CGColor] = [:]
    private let highlightLayer = CAShapeLayer()
    private let centreLayer = CAShapeLayer()
    private let focusLayer = CAShapeLayer()
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

    // MARK: Keyboard focus

    /// Keys while the chart has focus (arrow traversal, Return, Space);
    /// returns false for keys it doesn't handle.
    var onKey: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func becomeFirstResponder() -> Bool {
        // Focus from a click shows nothing; from Tab (or VoiceOver) it does.
        let mouse: Set<NSEvent.EventType> = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        keyboardFocus = !(NSApp.currentEvent.map { mouse.contains($0.type) } ?? false)
        DispatchQueue.main.async { [weak self] in self?.updateFocusLayer() }
        return true
    }

    override func resignFirstResponder() -> Bool {
        keyboardFocus = false
        DispatchQueue.main.async { [weak self] in self?.updateFocusLayer() }
        return true
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true {
            // Arrow keys after a click: the focus becomes visible (as :focus-visible).
            if !keyboardFocus { keyboardFocus = true; updateFocusLayer() }
            return
        }
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        if Int(event.keyCode) == KeyCode.tab, mods.isEmpty {
            // Tab from the chart gives focus back to the list (the content view).
            window?.makeFirstResponder(window?.contentView)
            return
        }
        super.keyDown(with: event)
    }

    /// The keyboard-current segment (nil for none).
    func setSelectedIndex(_ index: Int?) {
        guard index != selectedIndex else { return }
        selectedIndex = index
        updateFocusLayer()
    }

    /// Outlines the keyboard-current segment in the accent colour while the
    /// chart holds keyboard focus in the key window; with no selection, a thin
    /// ring just outside the outermost ring.
    private func updateFocusLayer() {
        let g = geometry
        let visible = keyboardFocus && transition == nil && window?.firstResponder === self
            && (window?.isKeyWindow ?? false) && chartLayout != nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        focusLayer.isHidden = !visible
        if visible, let chartLayout {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                focusLayer.strokeColor = NSColor.controlAccentColor.cgColor
            }
            if let i = selectedIndex, i < chartLayout.segments.count {
                let s = chartLayout.segments[i]
                let path = CGMutablePath()
                addSegment(to: path, geometry: g, ringPosition: CGFloat(s.ring),
                           a0: s.startAngle, a1: s.endAngle, gap: gap)
                focusLayer.path = path
                focusLayer.lineWidth = highContrast ? 3 : 2
            } else {
                let r = g.outer + 3
                focusLayer.path = CGPath(ellipseIn: CGRect(x: g.center.x - r, y: g.center.y - r,
                                                          width: 2 * r, height: 2 * r), transform: nil)
                focusLayer.lineWidth = highContrast ? 2 : 1.5
            }
        } else {
            focusLayer.path = nil
        }
        CATransaction.commit()
    }

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
            let element = SegmentElement()
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(segmentLabel?(s) ?? "")
            element.setAccessibilityParent(self)
            // Parent space is bottom-left based even for a flipped view.
            var box = path.boundingBoxOfPath
            box.origin.y = bounds.height - box.maxY
            element.setAccessibilityFrameInParentSpace(box)
            element.index = i
            element.chart = self
            element.press = { [weak self] in self?.pressSegment(i) ?? false }
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
    private func pressSegment(_ i: Int) -> Bool {
        guard transition == nil, let chartLayout, i < chartLayout.segments.count else { return false }
        onClick?(chartLayout.segments[i], [])
        return true
    }

    private func invalidateAccessibility() {
        guard accessibilityElements != nil else { return }
        accessibilityElements = nil
        elementsByIndex = [:]
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

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

    private func startTransition(from old: SunburstLayout, to new: SunburstLayout,
                                 fromTitle: String, fromSubtitle: String) {
        let kind: Transition.Kind
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            kind = .crossfade
        } else if let s = old.segments.first(where: { $0.node == new.root }) {
            kind = .zoomIn(ring: s.ring, a0: s.startAngle, a1: s.endAngle)
        } else if let s = new.segments.first(where: { $0.node == old.root }) {
            kind = .zoomOut(ring: s.ring, a0: s.startAngle, a1: s.endAngle)
        } else {
            kind = .crossfade
        }
        let duration: TimeInterval
        if case .crossfade = kind { duration = Self.crossfadeDuration } else { duration = Self.animationDuration }
        transition = Transition(kind: kind, from: old, fromTitle: fromTitle, fromSubtitle: fromSubtitle,
                                start: CACurrentMediaTime(), duration: duration)
        startLink()
        needsDisplay = true
    }

    // MARK: Display link (navigation animation only)

    private func startLink() {
        guard link == nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if let t = transition, now - t.start >= t.duration {
            finishTransition()
        }
        if transition == nil { stopLink() }
        needsDisplay = true
    }

    private func finishTransition() {
        guard let t = transition else { return }
        if t.frames > 1 {
            let elapsed = t.lastFrame - t.start
            if elapsed > 0 { Timings.mark("drillFPS", Double(t.frames) / elapsed) }
        }
        transition = nil
        frameContext = nil
        refreshHoverFromMouse()
    }

    // MARK: Geometry

    private struct Geometry {
        let center: CGPoint
        let outer: CGFloat
        let inner: CGFloat
        let ringWidth: CGFloat
        var discRadius: CGFloat { inner - 3 }

        func innerRadius(ringPosition p: CGFloat) -> CGFloat { inner + (p - 1) * ringWidth }
    }

    private var geometry: Geometry {
        let side = max(min(bounds.width, bounds.height) - 2 * Self.padding, 80)
        let outer = side / 2
        let inner = max(outer * 0.27, 40)
        return Geometry(center: CGPoint(x: bounds.midX, y: bounds.midY), outer: outer, inner: inner,
                        ringWidth: max((outer - inner) / CGFloat(SunburstLayout.maxRings), 1))
    }

    private enum Hit: Equatable { case segment(Int), centre, none }

    private func hit(at point: CGPoint) -> Hit {
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

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited,
                                                         .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { updateHover(event: event) }
    override func mouseEntered(with event: NSEvent) { updateHover(event: event) }

    override func mouseExited(with event: NSEvent) {
        setHover(.none, timestamp: event.timestamp)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if keyboardFocus { keyboardFocus = false; updateFocusLayer() }
        // Control-click is a context-menu click, never a drill.
        if event.modifierFlags.contains(.control) {
            pressedHit = nil
            showContextMenu(for: event)
            return
        }
        pressedHit = hit(at: convert(event.locationInWindow, from: nil))
    }

    override func rightMouseDown(with event: NSEvent) {
        pressedHit = nil
        showContextMenu(for: event)
    }

    private func showContextMenu(for event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func mouseUp(with event: NSEvent) {
        let h = hit(at: convert(event.locationInWindow, from: nil))
        defer { pressedHit = nil }
        guard pressedHit != nil, !event.modifierFlags.contains(.control) else { return }
        guard h == pressedHit, transition == nil, let chartLayout else { return }
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        switch h {
        case .centre: if canGoUp { onCentreClick?() }
        case .segment(let i): onClick?(chartLayout.segments[i], flags)
        case .none: break
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard transition == nil, let chartLayout,
              case .segment(let i) = hit(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return onMenu?(chartLayout.segments[i])
    }

    // MARK: Gestures

    /// Pinch-open enters the item under the pointer (or the selection);
    /// pinch-close goes to the enclosing folder. Fires once per gesture.
    override func magnify(with event: NSEvent) {
        if event.phase == .began { pinch = 0 }
        guard var amount = pinch else {
            if event.phase == .ended || event.phase == .cancelled { pinch = 0 }
            return
        }
        amount += event.magnification
        if abs(amount) >= Self.pinchThreshold {
            pinch = nil
            onPinch?(amount > 0)
        } else {
            pinch = amount
        }
        if event.phase == .ended || event.phase == .cancelled { pinch = 0 }
    }

    /// Three-finger (or "swipe between pages") swipes: back / forward.
    override func swipe(with event: NSEvent) {
        if event.deltaX > 0 { onSwipe?(true) } else if event.deltaX < 0 { onSwipe?(false) }
    }

    override func wantsScrollEventsForSwipeTracking(on axis: NSEvent.GestureAxis) -> Bool {
        axis == .horizontal
    }

    /// Two-finger horizontal swipes (with "Swipe between pages" on): back / forward.
    override func scrollWheel(with event: NSEvent) {
        guard event.phase == .began, NSEvent.isSwipeTrackingFromScrollEventsEnabled,
              abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else {
            super.scrollWheel(with: event)
            return
        }
        let (back, forward) = canSwipe?() ?? (false, false)
        guard back || forward else { return }
        var fired = false
        event.trackSwipeEvent(options: [.lockDirection, .clampGestureAmount],
                              dampenAmountThresholdMin: forward ? -1 : 0, max: back ? 1 : 0) {
            [weak self] amount, phase, _, _ in
            guard phase == .ended, !fired, amount != 0 else { return }
            fired = true
            MainActor.assumeIsolated { self?.onSwipe?(amount > 0) }
        }
    }

    private func updateHover(event: NSEvent) {
        guard transition == nil else { return }
        setHover(hit(at: convert(event.locationInWindow, from: nil)), timestamp: event.timestamp)
    }

    private func refreshHoverFromMouse() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHover(bounds.contains(point) ? hit(at: point) : .none, timestamp: nil)
    }

    /// Updates and commits the highlight first, then tells the model (which
    /// retargets the side list in a later SwiftUI update).
    private func setHover(_ h: Hit, timestamp: TimeInterval?) {
        let newIndex: Int?
        if case .segment(let i) = h { newIndex = i } else { newIndex = nil }
        let newCentre = h == .centre && canGoUp
        let centreChanged = newCentre != centreHovered
        centreHovered = newCentre
        let changed = newIndex != hoverIndex
        guard changed || centreChanged else { return }
        hoverIndex = newIndex
        updateHighlightLayer(animated: true)
        // Push the highlight to the render server now, ahead of the list update.
        CATransaction.flush()
        guard changed else { return }
        if let timestamp { Timings.mark("hover", (Timings.now - timestamp) * 1000) }
        onHover?(newIndex.flatMap { chartLayout?.segments[$0] })
    }

    /// Points the highlight layer at the hovered (or list-hovered) segment.
    private func updateHighlightLayer(animated: Bool) {
        let g = geometry
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        centreLayer.isHidden = !(centreHovered && transition == nil)
        if !centreLayer.isHidden { centreLayer.path = CGPath(ellipseIn: discRect(g), transform: nil) }

        let index = transition == nil ? (hoverIndex ?? externalIndex) : nil
        if index != shownHighlight {
            shownHighlight = index
            highlightLayer.removeAnimation(forKey: "fade")
            if let index, let chartLayout, index < chartLayout.segments.count {
                let s = chartLayout.segments[index]
                let path = CGMutablePath()
                addSegment(to: path, geometry: g, ringPosition: CGFloat(s.ring),
                           a0: s.startAngle, a1: s.endAngle, gap: gap)
                highlightLayer.path = path
                highlightLayer.isHidden = false
                if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = 0
                    fade.toValue = 1
                    fade.duration = Self.highlightFade
                    highlightLayer.add(fade, forKey: "fade")
                }
            } else {
                highlightLayer.path = nil
                highlightLayer.isHidden = true
            }
        }
        CATransaction.commit()
        updateFocusLayer()
    }

    // MARK: Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidateCache()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        invalidateCache()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        invalidateCache()
        shownHighlight = nil   // geometry changed: rebuild the highlight path
        updateHighlightLayer(animated: false)
        invalidateAccessibility()
    }

    private func invalidateCache() {
        cacheValid = false
        colorCache.removeAll()
        frameContext = nil
        needsDisplay = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = appearanceKind == .dark
            highlightLayer.fillColor = CGColor(gray: 1, alpha: dark ? 0.28 : 0.45)
            highlightLayer.strokeColor = NSColor.labelColor
                .withAlphaComponent(highContrast ? 0.85 : dark ? 0.5 : 0.35).cgColor
            highlightLayer.lineWidth = highContrast ? 1.5 : 1
            centreLayer.fillColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        }
    }

    private var appearanceKind: Appearance {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    private var highContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }

    private struct ColorKey: Hashable {
        let kind: SegmentKind
        let hue: Int
        let ring: Int
    }

    private func color(for s: Segment) -> CGColor {
        let hue = s.kind == .folder ? ((s.topLevelIndex % Palette.hueCount) + Palette.hueCount) % Palette.hueCount : 0
        let key = ColorKey(kind: s.kind, hue: hue, ring: min(s.ring, SunburstLayout.maxRings))
        if let c = colorCache[key] { return c }
        let rgb = Palette.color(kind: s.kind, topLevelIndex: hue, ring: key.ring,
                                appearance: appearanceKind, highContrast: highContrast)
        let alpha: CGFloat = s.kind == .smallerObjects ? 0.6 : 1
        let c = CGColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: alpha)
        colorCache[key] = c
        return c
    }

    // MARK: Drawing

    override func updateLayer() {
        guard let backing = layer, let chartLayout, !bounds.isEmpty else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        backing.contentsScale = scale
        let g = geometry
        let now = CACurrentMediaTime()

        if var t = transition {
            let drawStart = Timings.now
            let raw = min(max((now - t.start) / t.duration, 0), 1)
            let e = CGFloat(raw < 0.5 ? 2 * raw * raw : 1 - pow(-2 * raw + 2, 2) / 2)   // ease-in-out
            let image = render(into: &frameContext, scale: scale) { ctx in
                drawTransition(t, progress: e, to: chartLayout, in: ctx, geometry: g)
            }
            backing.contents = image
            showingCache = false
            t.frames += 1
            if t.frames > 1 { Timings.mark("frameInterval", (now - t.lastFrame) * 1000) }
            t.lastFrame = now
            transition = t
            Timings.mark("frame", (Timings.now - drawStart) * 1000)
        } else if !cacheValid || !showingCache {
            if !cacheValid {
                cacheValid = true
                var context: CGContext?
                cache = render(into: &context, scale: scale) { ctx in
                    drawDisc(in: ctx, geometry: g)
                    drawSegments(chartLayout.segments, in: ctx, geometry: g) { s in
                        (Double(s.ring), s.startAngle, s.endAngle)
                    }
                    drawLabels(title: title, subtitle: subtitle, alpha: 1, geometry: g)
                }
            }
            backing.contents = cache
            showingCache = true
            updateHighlightLayer(animated: false)
        }

        if !firstFrameDone {
            firstFrameDone = true
            onFirstFrame?()
        }
    }

    /// Renders into a bitmap at backing scale in the view's (flipped)
    /// coordinates, reusing `context` while its size matches.
    private func render(into context: inout CGContext?, scale: CGFloat, _ body: (CGContext) -> Void) -> CGImage? {
        let width = Int((bounds.width * scale).rounded(.up)), height = Int((bounds.height * scale).rounded(.up))
        guard width > 0, height > 0 else { return nil }
        if context == nil || context?.width != width || context?.height != height {
            context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let ctx = context else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        effectiveAppearance.performAsCurrentDrawingAppearance { body(ctx) }
        NSGraphicsContext.current = previous
        ctx.restoreGState()
        return ctx.makeImage()
    }

    private func drawTransition(_ t: Transition, progress e: CGFloat, to new: SunburstLayout,
                                in ctx: CGContext, geometry g: Geometry) {
        drawDisc(in: ctx, geometry: g)
        ctx.saveGState()
        // Rings pushed outward during a zoom are clipped at the chart's edge.
        ctx.addEllipse(in: CGRect(x: g.center.x - g.outer, y: g.center.y - g.outer,
                                  width: 2 * g.outer, height: 2 * g.outer))
        ctx.clip()
        let ed = Double(e)
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * ed }
        switch t.kind {
        case .crossfade:
            ctx.setAlpha(1 - e)
            drawSegments(t.from.segments, in: ctx, geometry: g) { (Double($0.ring), $0.startAngle, $0.endAngle) }
            ctx.setAlpha(e)
            drawSegments(new.segments, in: ctx, geometry: g) { (Double($0.ring), $0.startAngle, $0.endAngle) }
        case .zoomIn(let ring, let a0, let a1):
            let k = (a1 - a0) / (2 * .pi)
            ctx.setAlpha(1 - e)
            drawSegments(t.from.segments, in: ctx, geometry: g) { (Double($0.ring), $0.startAngle, $0.endAngle) }
            ctx.setAlpha(1)
            drawSegments(new.segments, in: ctx, geometry: g) { s in
                (lerp(Double(s.ring + ring), Double(s.ring)),
                 lerp(a0 + s.startAngle * k, s.startAngle), lerp(a0 + s.endAngle * k, s.endAngle))
            }
        case .zoomOut(let ring, let a0, let a1):
            let k = (a1 - a0) / (2 * .pi)
            ctx.setAlpha(e)
            drawSegments(new.segments, in: ctx, geometry: g) { (Double($0.ring), $0.startAngle, $0.endAngle) }
            ctx.setAlpha(1 - e)
            drawSegments(t.from.segments, in: ctx, geometry: g) { s in
                (lerp(Double(s.ring), Double(s.ring + ring)),
                 lerp(s.startAngle, a0 + s.startAngle * k), lerp(s.endAngle, a0 + s.endAngle * k))
            }
        }
        ctx.restoreGState()
        drawLabels(title: t.fromTitle, subtitle: t.fromSubtitle, alpha: 1 - e, geometry: g)
        drawLabels(title: title, subtitle: subtitle, alpha: e, geometry: g)
    }

    private var gap: CGFloat { Palette.segmentGap(appearance: appearanceKind, highContrast: highContrast) }

    /// Fills (or, for mount points, outlines) `segments`, one path per colour.
    /// `place` gives each segment's (ring position, start, end), possibly mid-animation.
    private func drawSegments(_ segments: [Segment], in ctx: CGContext, geometry g: Geometry,
                              place: (Segment) -> (Double, Double, Double)) {
        let gap = self.gap
        var fills: [CGColor: CGMutablePath] = [:]
        var outlines: [CGColor: CGMutablePath] = [:]
        let maxRing = Double(SunburstLayout.maxRings) + 1
        for s in segments {
            let (ring, a0, a1) = place(s)
            guard ring < maxRing, a1 > a0 else { continue }
            let c = color(for: s)
            let path: CGMutablePath
            if s.kind == .mountPoint {
                if let p = outlines[c] { path = p } else { path = CGMutablePath(); outlines[c] = path }
            } else {
                if let p = fills[c] { path = p } else { path = CGMutablePath(); fills[c] = path }
            }
            addSegment(to: path, geometry: g, ringPosition: CGFloat(ring), a0: a0, a1: a1, gap: gap)
        }
        for (c, path) in fills {
            ctx.addPath(path)
            ctx.setFillColor(c)
            ctx.fillPath()
        }
        ctx.setLineWidth(1)
        for (c, path) in outlines {
            ctx.addPath(path)
            ctx.setStrokeColor(c)
            ctx.strokePath()
        }
    }

    /// An annular sector with a constant-width gap around it. Angles: 0 = 12
    /// o'clock, clockwise; the gap's angular share is capped so slivers stay visible.
    private func addSegment(to path: CGMutablePath, geometry g: Geometry, ringPosition: CGFloat,
                            a0: Double, a1: Double, gap: CGFloat) {
        let ri = g.innerRadius(ringPosition: ringPosition) + gap / 2
        let ro = ri + g.ringWidth - gap
        guard ro > ri, ri > 0 else { return }
        let span = a1 - a0
        let quarter = Double.pi / 2
        if span >= 2 * .pi - 1e-6 {
            // A single child filling the ring: a full annulus (inner circle reversed).
            // Each subpath starts with a move: `addArc` would otherwise join it to the previous one.
            path.move(to: CGPoint(x: g.center.x + ro, y: g.center.y))
            path.addArc(center: g.center, radius: ro, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            path.closeSubpath()
            path.move(to: CGPoint(x: g.center.x + ri, y: g.center.y))
            path.addArc(center: g.center, radius: ri, startAngle: 2 * .pi, endAngle: 0, clockwise: true)
            path.closeSubpath()
            return
        }
        let dOuter = min(Double(gap / 2 / ro), span * 0.3)
        let dInner = min(Double(gap / 2 / ri), span * 0.3)
        let start = a0 + dOuter - quarter
        path.move(to: CGPoint(x: g.center.x + ro * cos(start), y: g.center.y + ro * sin(start)))
        path.addArc(center: g.center, radius: ro, startAngle: a0 + dOuter - quarter,
                    endAngle: a1 - dOuter - quarter, clockwise: false)
        path.addArc(center: g.center, radius: ri, startAngle: a1 - dInner - quarter,
                    endAngle: a0 + dInner - quarter, clockwise: true)
        path.closeSubpath()
    }

    private func discRect(_ g: Geometry) -> CGRect {
        CGRect(x: g.center.x - g.discRadius, y: g.center.y - g.discRadius,
               width: 2 * g.discRadius, height: 2 * g.discRadius)
    }

    private func drawDisc(in ctx: CGContext, geometry g: Geometry) {
        let dark = appearanceKind == .dark
        ctx.setFillColor(NSColor.labelColor.withAlphaComponent(dark ? 0.07 : 0.035).cgColor)
        ctx.fillEllipse(in: discRect(g))
    }

    /// Size (large, never truncated: the font shrinks to fit, down to 13 pt) over the name
    /// (small, truncated in the middle).
    private func drawLabels(title: String, subtitle: String, alpha: CGFloat, geometry g: Geometry) {
        guard alpha > 0.01 else { return }
        let width = g.discRadius * 1.5
        var titleSize: CGFloat = min(26, max(15, g.discRadius * 0.3))
        var titleAttrs: [NSAttributedString.Key: Any] = [:]
        var titleWidth: CGFloat = 0
        repeat {
            titleAttrs = [.font: NSFont.monospacedDigitSystemFont(ofSize: titleSize, weight: .semibold),
                          .foregroundColor: NSColor.labelColor.withAlphaComponent(alpha)]
            titleWidth = (title as NSString).size(withAttributes: titleAttrs).width
            titleSize -= 1
        } while titleWidth > width && titleSize >= 13   // never below 13 pt (may overhang the disc)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            // Increase Contrast: full-contrast text.
            .foregroundColor: (highContrast ? NSColor.labelColor : NSColor.secondaryLabelColor)
                .withAlphaComponent(alpha),
            .paragraphStyle: paragraph,
        ]
        let titleHeight = (titleAttrs[.font] as? NSFont).map { $0.ascender - $0.descender + $0.leading } ?? 24
        let subHeight: CGFloat = 17
        let top = g.center.y - (titleHeight + 2 + subHeight) / 2
        (title as NSString).draw(at: CGPoint(x: g.center.x - titleWidth / 2, y: top), withAttributes: titleAttrs)
        (subtitle as NSString).draw(with: CGRect(x: g.center.x - width / 2, y: top + titleHeight + 2,
                                                 width: width, height: subHeight),
                                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                    attributes: subAttrs)
    }
}

/// A ring-1 segment as an accessibility element; VoiceOver's press opens it.
private final class SegmentElement: NSAccessibilityElement {
    var index = 0
    var press: (() -> Bool)?
    nonisolated(unsafe) weak var chart: SunburstChartView?

    override func accessibilityPerformPress() -> Bool { press?() ?? false }

    /// A segment's frame is its bounding box, which overlaps its neighbours';
    /// the chart resolves the point against the real ring geometry.
    override nonisolated func accessibilityHitTest(_ point: NSPoint) -> Any? {
        chart?.accessibilityElement(atScreen: point) ?? self
    }
}
