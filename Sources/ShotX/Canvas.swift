import AppKit
import Combine
import UniformTypeIdentifiers

final class EditorModel: ObservableObject {
    @Published var tool: Tool = .arrow
    @Published var color: NSColor = Palette.colors[0]
    @Published var width: CGFloat = 4
    @Published private(set) var annotations: [Annotation] = []
    @Published private(set) var undoStack: [[Annotation]] = []
    @Published private(set) var redoStack: [[Annotation]] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var nextCounter: Int { (annotations.filter { $0.tool == .counter }.map(\.number).max() ?? 0) + 1 }

    /// Records the current state so the next change can be undone.
    func checkpoint() {
        undoStack.append(annotations)
        redoStack.removeAll()
    }

    /// Drops a checkpoint that turned out not to change anything (e.g. a click without a drag).
    func discardCheckpoint() { _ = undoStack.popLast() }

    func add(_ a: Annotation, recordUndo: Bool = true) {
        if recordUndo { checkpoint() }
        annotations.append(a)
    }

    /// Live update without touching history (callers checkpoint first).
    func replace(at i: Int, with a: Annotation) { annotations[i] = a }

    func remove(at i: Int, recordUndo: Bool = true) {
        if recordUndo { checkpoint() }
        annotations.remove(at: i)
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = prev
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
    }

    // Toolbar → window actions
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onClose: (() -> Void)?
}

enum Palette {
    static let colors: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1), // red
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1), // orange
        NSColor(srgbRed: 1.00, green: 0.84, blue: 0.04, alpha: 1), // yellow
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1), // green
        NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1), // blue
        NSColor(srgbRed: 0.75, green: 0.35, blue: 0.95, alpha: 1), // purple
        NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1), // white
        NSColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1), // black
    ]
    static let widths: [CGFloat] = [2, 4, 7]
}

/// Interactive drawing surface. Annotations live in image-point coordinates;
/// the view scales them to whatever size it's displayed at.
final class CanvasView: NSView, NSTextFieldDelegate {
    let model: EditorModel
    let shot: CroppedShot
    let renderer: Renderer
    private var current: Annotation?
    private var textField: NSTextField?
    private var textOrigin: CGPoint = .zero
    private var moving: (index: Int, last: CGPoint, moved: Bool)?
    private(set) var selectedIndex: Int? { didSet { if oldValue != selectedIndex { needsDisplay = true } } }
    private var hoverIndex: Int? { didSet { if oldValue != hoverIndex { needsDisplay = true } } }
    private var cancellables: Set<AnyCancellable> = []

    init(model: EditorModel, shot: CroppedShot) {
        self.model = model
        self.shot = shot
        self.renderer = Renderer(base: shot.image,
                                 pixelated: Renderer.makePixelated(shot.image, scale: shot.scale),
                                 size: shot.pointSize)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.modelChanged() }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                                                               .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { hoverIndex = nil }

    private func updateHover(_ event: NSEvent) {
        guard moving == nil else { NSCursor.move.set(); return }
        guard textField == nil else { return }
        hoverIndex = movableIndex(at: imagePoint(event))
        if hoverIndex != nil { NSCursor.move.set() }
        else { (model.tool == .text ? NSCursor.iBeam : NSCursor.crosshair).set() }
    }

    /// Bounds (image points) of an annotation that can be selected and moved: labels and step numbers.
    private func movableRect(_ a: Annotation) -> CGRect? {
        switch a.tool {
        case .text:
            let size = NSAttributedString(string: a.text, attributes: [.font: a.font]).size()
            return CGRect(origin: a.start, size: size)
        case .counter:
            let r = 9 + a.width * 2
            return CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2)
        default:
            return nil
        }
    }

    private func movableIndex(at p: CGPoint) -> Int? {
        model.annotations.indices.reversed().first { i in
            movableRect(model.annotations[i])?.insetBy(dx: -6, dy: -4).contains(p) ?? false
        }
    }

    /// Valid index of a movable annotation (indices can go stale after undo/redo).
    private func validMovable(_ i: Int?) -> Int? {
        guard let i, model.annotations.indices.contains(i), movableRect(model.annotations[i]) != nil else { return nil }
        return i
    }

    private var viewScale: CGFloat { bounds.width / shot.pointSize.width }

    private func modelChanged() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        if let field = textField {
            field.textColor = model.color
            field.font = NSFont.systemFont(ofSize: (10 + model.width * 3) * viewScale, weight: .bold)
            field.sizeToFit()
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.scaleBy(x: viewScale, y: viewScale)
        var all = model.annotations
        if let current { all.append(current) }
        renderer.drawAll(all, ctx: ctx)
        ctx.restoreGState()

        if let i = validMovable(selectedIndex), let r = movableRect(model.annotations[i]) {
            drawSelectionBox(viewRect(r), ctx: ctx)
        } else if let i = validMovable(hoverIndex), let r = movableRect(model.annotations[i]) {
            let box = viewRect(r)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
    }

    private func viewRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * viewScale, y: r.minY * viewScale, width: r.width * viewScale, height: r.height * viewScale)
            .insetBy(dx: -6, dy: -4).integral.insetBy(dx: 0.5, dy: 0.5)
    }

    private func drawSelectionBox(_ box: CGRect, ctx: CGContext) {
        let accent = NSColor.controlAccentColor.cgColor
        ctx.saveGState()
        // Dark halo keeps the box visible on light and dark screenshots alike.
        ctx.setShadow(offset: .zero, blur: 3, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(1.5)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.strokePath()
        ctx.restoreGState()

        for c in [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                  CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)] {
            let handle = CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(1.5)
            ctx.addPath(CGPath(roundedRect: handle, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            ctx.drawPath(using: .fillStroke)
        }
    }

    // MARK: Mouse

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x, 0), bounds.width) / viewScale,
                       y: min(max(p.y, 0), bounds.height) / viewScale)
    }

    override func mouseDown(with event: NSEvent) {
        if textField != nil { commitText(); return }
        window?.makeFirstResponder(self)
        let p = imagePoint(event)

        if let i = movableIndex(at: p) {
            let a = model.annotations[i]
            if event.clickCount == 2, a.tool == .text {
                // Double-click a label to edit it in place, keeping its style.
                selectedIndex = nil
                hoverIndex = nil
                model.remove(at: i)
                model.color = a.color
                model.width = a.width
                beginText(at: a.start, text: a.text, replacingExisting: true)
            } else {
                selectedIndex = i
                model.checkpoint()
                moving = (i, p, false)
                NSCursor.move.set()
            }
            return
        }
        selectedIndex = nil

        switch model.tool {
        case .text:
            beginText(at: p)
        case .counter:
            model.add(Annotation(tool: .counter, color: model.color, width: model.width, points: [p], number: model.nextCounter))
        default:
            current = Annotation(tool: model.tool, color: model.color, width: model.width, points: [p, p])
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let m = moving {
            let p = imagePoint(event)
            var a = model.annotations[m.index]
            a.points = a.points.map { CGPoint(x: $0.x + p.x - m.last.x, y: $0.y + p.y - m.last.y) }
            model.replace(at: m.index, with: a)
            moving = (m.index, p, true)
            return
        }
        guard var a = current else { return }
        var p = imagePoint(event)
        switch a.tool {
        case .pen, .highlighter:
            if let last = a.points.last, hypot(p.x - last.x, p.y - last.y) < 1.5 { return }
            if a.points.count == 2 && a.points[0] == a.points[1] { a.points.removeLast() }
            if event.modifierFlags.contains(.shift), a.tool == .highlighter {
                // Straight highlighter line, constrained to horizontal/vertical.
                let s = a.start
                p = abs(p.x - s.x) > abs(p.y - s.y) ? CGPoint(x: p.x, y: s.y) : CGPoint(x: s.x, y: p.y)
                a.points = [s, p]
            } else {
                a.points.append(p)
            }
        default:
            if event.modifierFlags.contains(.shift) { p = constrain(from: a.start, to: p, tool: a.tool) }
            a.points[a.points.count - 1] = p
        }
        current = a
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let m = moving {
            if !m.moved { model.discardCheckpoint() }
            moving = nil
            NSCursor.move.set()
            return
        }
        guard let a = current else { return }
        current = nil
        let meaningful: Bool
        switch a.tool {
        case .pen, .highlighter: meaningful = true
        case .arrow: meaningful = hypot(a.end.x - a.start.x, a.end.y - a.start.y) > 4
        default: meaningful = a.rect.width > 3 && a.rect.height > 3
        }
        if meaningful { model.add(a) } else { needsDisplay = true }
    }

    private func constrain(from s: CGPoint, to p: CGPoint, tool: Tool) -> CGPoint {
        let dx = p.x - s.x, dy = p.y - s.y
        if tool == .arrow {
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let len = hypot(dx, dy)
            return CGPoint(x: s.x + cos(angle) * len, y: s.y + sin(angle) * len)
        }
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: s.x + (dx < 0 ? -side : side), y: s.y + (dy < 0 ? -side : side))
    }

    // MARK: Text

    private var editingExisting = false

    private func beginText(at p: CGPoint, text: String = "", replacingExisting: Bool = false) {
        textOrigin = p
        editingExisting = replacingExisting
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = true
        field.textColor = model.color
        field.font = NSFont.systemFont(ofSize: (10 + model.width * 3) * viewScale, weight: .bold)
        field.placeholderString = "Type…"
        field.delegate = self
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.sizeToFit()
        field.frame.size.width = max(160, field.frame.width + 24)
        // NSTextField has a ~2pt inset; nudge so committed text lands where it was typed.
        field.frame.origin = CGPoint(x: p.x * viewScale - 2, y: p.y * viewScale)
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = textField else { return }
        let w = field.attributedStringValue.size().width + 24
        field.frame.size.width = max(160, min(w, bounds.width - field.frame.minX))
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            textField?.stringValue = ""
            commitText()
            return true
        }
        return false
    }

    @discardableResult
    func commitText() -> Bool {
        guard let field = textField else { return false }
        textField = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.delegate = nil
        field.removeFromSuperview()
        if !text.isEmpty {
            // An edited label reuses the checkpoint taken when it was picked up, so one undo restores it.
            model.add(Annotation(tool: .text, color: model.color, width: model.width, points: [textOrigin], text: text),
                      recordUndo: !editingExisting)
        }
        editingExisting = false
        window?.makeFirstResponder(self)
        return true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if !handleShortcut(event) { super.keyDown(with: event) }
    }

    /// Esc discards, Return copies, letters pick tools, 1–8 pick colors. Returns true if handled.
    func handleShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if let i = validMovable(selectedIndex) {
            switch event.keyCode {
            case 53:                                   // Esc: deselect first
                selectedIndex = nil
                return true
            case 51, 117:                              // Delete / Forward Delete
                selectedIndex = nil
                hoverIndex = nil
                model.remove(at: i)
                return true
            case 123, 124, 125, 126:                   // Arrow keys nudge (Shift = 10pt)
                let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
                let d: CGPoint = [123: CGPoint(x: -step, y: 0), 124: CGPoint(x: step, y: 0),
                                  125: CGPoint(x: 0, y: step), 126: CGPoint(x: 0, y: -step)][event.keyCode]!
                var a = model.annotations[i]
                a.points = a.points.map { CGPoint(x: $0.x + d.x, y: $0.y + d.y) }
                model.checkpoint()
                model.replace(at: i, with: a)
                return true
            default: break
            }
        }
        switch event.keyCode {
        case 53:                                       // Esc: drop an in-progress stroke, else discard the shot
            if current != nil { current = nil; needsDisplay = true } else { model.onClose?() }
            return true
        case 36, 76:                                   // Return / Enter
            model.onCopy?()
            return true
        default: break
        }
        guard flags.isEmpty, let ch = event.charactersIgnoringModifiers?.lowercased().first else { return false }
        if let tool = Tool.allCases.first(where: { $0.shortcut == ch }) { model.tool = tool; return true }
        if let n = ch.wholeNumberValue, (1...Palette.colors.count).contains(n) { model.color = Palette.colors[n - 1]; return true }
        return false
    }

    @objc func undo(_ sender: Any?) { model.undo() }
    @objc func redo(_ sender: Any?) { model.redo() }
    @objc func copy(_ sender: Any?) { model.onCopy?() }
    @objc func saveDocument(_ sender: Any?) { model.onSave?() }
    override func cancelOperation(_ sender: Any?) { model.onClose?() }

    // MARK: Export

    func renderFinal() -> CGImage? {
        commitText()
        return renderer.export(model.annotations, pixelScale: shot.scale)
    }
}

extension NSCursor {
    /// Four-way "move" cursor (AppKit has no public one): white arrows with a dark outline.
    static let move: NSCursor = {
        let size = NSSize(width: 26, height: 26)
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .bold)
        guard let symbol = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return .openHand }

        func tinted(_ color: NSColor) -> NSImage {
            NSImage(size: symbol.size, flipped: false) { r in
                symbol.draw(in: r)
                color.set()
                r.fill(using: .sourceAtop)
                return true
            }
        }
        let image = NSImage(size: size, flipped: false) { rect in
            let origin = NSPoint(x: (rect.width - symbol.size.width) / 2, y: (rect.height - symbol.size.height) / 2)
            let outline = tinted(.black)
            for dx in stride(from: -1.5, through: 1.5, by: 1.5) {
                for dy in stride(from: -1.5, through: 1.5, by: 1.5) where dx != 0 || dy != 0 {
                    outline.draw(at: NSPoint(x: origin.x + dx, y: origin.y + dy), from: .zero, operation: .sourceOver, fraction: 0.9)
                }
            }
            tinted(.white).draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
    }()
}
