import AppKit

final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func performClose(_ sender: Any?) { close() }
}

/// One frozen, dimmed overlay per display. Drag to select; Esc to cancel.
final class SelectionController {
    private var windows: [KeyableWindow] = []
    private let completion: (CroppedShot?) -> Void
    private var finished = false
    private var keyMonitor: Any?

    init(shots: [ScreenShot], completion: @escaping (CroppedShot?) -> Void) {
        self.completion = completion
        for shot in shots {
            let window = KeyableWindow(contentRect: shot.screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(shot.screen.frame, display: false)
            window.level = .screenSaver
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isReleasedWhenClosed = false

            let view = SelectionView(shot: shot)
            view.onFinish = { [weak self] result in self?.finish(result) }
            view.onPeerActivity = { [weak self, weak view] in
                // Only one display keeps guides/selection at a time.
                self?.windows.forEach { w in
                    if let other = w.contentView as? SelectionView, other !== view { other.clearTransientState() }
                }
            }
            window.contentView = view
            windows.append(window)
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        for window in windows { window.orderFrontRegardless() }
        let mouse = NSEvent.mouseLocation
        let target = windows.first { $0.frame.contains(mouse) } ?? windows.first
        target?.makeKeyAndOrderFront(nil)
        target?.makeFirstResponder(target?.contentView)
        NSCursor.crosshair.set()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }  // Esc cancels from any display
            self?.finish(nil)
            return nil
        }
    }

    private func finish(_ result: CroppedShot?) {
        guard !finished else { return }
        finished = true
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        NSCursor.arrow.set()
        completion(result)
    }
}

final class SelectionView: NSView {
    private let shot: ScreenShot
    private let nsImage: NSImage
    private var dragStart: NSPoint?
    private var selection: NSRect?
    private var mouse: NSPoint?

    var onFinish: ((CroppedShot?) -> Void)?
    var onPeerActivity: (() -> Void)?

    init(shot: ScreenShot) {
        self.shot = shot
        self.nsImage = NSImage(cgImage: shot.image, size: shot.screen.frame.size)
        super.init(frame: NSRect(origin: .zero, size: shot.screen.frame.size))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    func clearTransientState() {
        guard mouse != nil || selection != nil else { return }
        mouse = nil
        selection = nil
        dragStart = nil
        needsDisplay = true
    }

    // MARK: Events

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        NSCursor.crosshair.set()
    }

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        onPeerActivity?()
        NSCursor.crosshair.set()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        if dragStart == nil { mouse = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        dragStart = convert(event.locationInWindow, from: nil)
        selection = nil
        onPeerActivity?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        var p = convert(event.locationInWindow, from: nil)
        p.x = min(max(p.x, 0), bounds.width)
        p.y = min(max(p.y, 0), bounds.height)
        mouse = p
        var rect = NSRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        if event.modifierFlags.contains(.shift) {
            let side = max(rect.width, rect.height)
            rect.size = NSSize(width: side, height: side)
            if p.x < start.x { rect.origin.x = start.x - side }
            if p.y < start.y { rect.origin.y = start.y - side }
        }
        selection = rect.integral
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard let rect = selection, rect.width >= 4, rect.height >= 4 else {
            selection = nil
            needsDisplay = true
            return
        }
        onFinish?(crop(rect))
    }

    override func rightMouseDown(with event: NSEvent) { onFinish?(nil) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) } // Esc
        else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onFinish?(nil) }

    private func crop(_ rect: NSRect) -> CroppedShot? {
        let s = shot.scale
        let pixelRect = CGRect(x: rect.minX * s,
                               y: (bounds.height - rect.maxY) * s,
                               width: rect.width * s,
                               height: rect.height * s).integral
        guard let cropped = shot.image.cropping(to: pixelRect) else { return nil }
        return CroppedShot(image: cropped, scale: s, screen: shot.screen)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        nsImage.draw(in: bounds)

        let dim = NSBezierPath(rect: bounds)
        if let sel = selection {
            dim.appendRect(sel)
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.45).setFill()
        dim.fill()

        if let sel = selection {
            drawSelection(sel)
        } else if let m = mouse {
            drawGuides(at: m)
        }
    }

    private func drawGuides(at p: NSPoint) {
        NSColor.white.withAlphaComponent(0.35).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: NSPoint(x: 0, y: floor(p.y) + 0.5))
        path.line(to: NSPoint(x: bounds.width, y: floor(p.y) + 0.5))
        path.move(to: NSPoint(x: floor(p.x) + 0.5, y: 0))
        path.line(to: NSPoint(x: floor(p.x) + 0.5, y: bounds.height))
        path.setLineDash([4, 4], count: 2, phase: 0)
        path.stroke()

        let px = Int(p.x * shot.scale), py = Int((bounds.height - p.y) * shot.scale)
        drawPill("\(px), \(py)", near: NSRect(x: p.x + 14, y: p.y - 34, width: 0, height: 0), anchorBelow: false)
    }

    private func drawSelection(_ sel: NSRect) {
        // Soft outer glow + crisp hairline.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 6
        shadow.set()
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // Corner handles
        NSColor.white.setFill()
        for corner in [NSPoint(x: sel.minX, y: sel.minY), NSPoint(x: sel.maxX, y: sel.minY),
                       NSPoint(x: sel.minX, y: sel.maxY), NSPoint(x: sel.maxX, y: sel.maxY)] {
            NSBezierPath(ovalIn: NSRect(x: corner.x - 3.5, y: corner.y - 3.5, width: 7, height: 7)).fill()
        }

        let w = Int(sel.width * shot.scale), h = Int(sel.height * shot.scale)
        drawPill("\(w) × \(h)", near: sel, anchorBelow: true)
    }

    private func drawPill(_ text: String, near rect: NSRect, anchorBelow: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let pad = NSSize(width: 9, height: 4)
        var box = NSRect(x: 0, y: 0, width: size.width + pad.width * 2, height: size.height + pad.height * 2)

        if anchorBelow {
            box.origin.x = rect.minX
            box.origin.y = rect.minY - box.height - 8
            if box.minY < 4 { box.origin.y = rect.maxY + 8 }
            if box.maxY > bounds.height - 4 { box.origin.y = rect.minY + 8 }
        } else {
            box.origin = rect.origin
        }
        box.origin.x = min(max(box.origin.x, 4), bounds.width - box.width - 4)
        box.origin.y = min(max(box.origin.y, 4), bounds.height - box.height - 4)

        NSColor(white: 0.08, alpha: 0.82).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        str.draw(at: NSPoint(x: box.minX + pad.width, y: box.minY + pad.height))
    }
}
