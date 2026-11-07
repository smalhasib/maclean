import AppKit
import MacleanCore
import MacleanKit
import QuartzCore
import SwiftUI

extension SunburstChartView {
    // MARK: Keyboard focus


    override func becomeFirstResponder() -> Bool {
        // Focus from a click shows nothing; from Tab (or VoiceOver) it does.
        let mouse: Set<NSEvent.EventType> = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        keyboardFocus = !(NSApp.currentEvent.map { mouse.contains($0.type) } ?? false)
        onFocus?()
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
            // Tab: on to the toolbar; Shift-Tab: back to the list. Both live in
            // the content view, which takes first responder.
            window?.makeFirstResponder(window?.contentView)
            onTabOut?(event.modifierFlags.contains(.shift))
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
    func updateFocusLayer() {
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
        onFocus?()
        if keyboardFocus { keyboardFocus = false; updateFocusLayer() }
        // Control-click is a context-menu click, never a drill.
        if event.modifierFlags.contains(.control) {
            pressedHit = nil
            showContextMenu(for: event)
            return
        }
        pressLocation = convert(event.locationInWindow, from: nil)
        pressedHit = hit(at: pressLocation!)
    }

    /// After `dragThreshold` of movement on a segment (not "smaller
    /// objects"), starts a drag carrying only `org.maclean.node`.
    override func mouseDragged(with event: NSEvent) {
        guard let start = pressLocation, case .segment(let i)? = pressedHit, transition == nil,
              let chartLayout, i < chartLayout.segments.count else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= Self.dragThreshold else { return }
        let segment = chartLayout.segments[i]
        guard segment.node != nil, let payload = onDragStart?(segment) else { return }
        pressedHit = nil
        pressLocation = nil
        NodeDrag.current = payload
        let item = NSPasteboardItem()
        item.setData(payload.data, forType: .macleanNode)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let icon = FileIcons.icon(for: payload.path)
        dragging.setDraggingFrame(NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32), contents: icon)
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        pressedHit = nil
        showContextMenu(for: event)
    }

    func showContextMenu(for event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func mouseUp(with event: NSEvent) {
        let h = hit(at: convert(event.locationInWindow, from: nil))
        defer { pressedHit = nil; pressLocation = nil }
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

    func updateHover(event: NSEvent) {
        guard transition == nil else { return }
        setHover(hit(at: convert(event.locationInWindow, from: nil)), timestamp: event.timestamp)
    }

    func refreshHoverFromMouse() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHover(bounds.contains(point) ? hit(at: point) : .none, timestamp: nil)
    }

    /// Updates and commits the highlight first, then tells the model (which
    /// retargets the side list in a later SwiftUI update).
    func setHover(_ h: Hit, timestamp: TimeInterval?) {
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
    func updateHighlightLayer(animated: Bool) {
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
}

// MARK: Drag source

extension SunburstChartView: NSDraggingSource {
    /// Inside Maclean only: a drop on Finder or another app is refused.
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.copy, .move, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        NodeDrag.current = nil
        refreshHoverFromMouse()
    }
}
