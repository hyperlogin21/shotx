import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class EditorWindowController: NSObject, NSWindowDelegate {
    private let window: KeyableWindow
    let model = EditorModel()
    let canvas: CanvasView
    private let shot: CroppedShot
    private var keyMonitor: Any?
    var onClose: (() -> Void)?

    private static let toolbarHeight: CGFloat = 52
    private static let padding: CGFloat = 14
    private static let minContentWidth: CGFloat = 620

    init(shot: CroppedShot) {
        self.shot = shot
        canvas = CanvasView(model: model, shot: shot)

        // Fit the capture on screen; display only. Export is always full resolution.
        let visible = (NSScreen.main ?? shot.screen).visibleFrame
        let maxW = visible.width * 0.9 - Self.padding * 2
        let maxH = visible.height * 0.9 - Self.padding * 2 - Self.toolbarHeight
        let fit = min(1, maxW / shot.pointSize.width, maxH / shot.pointSize.height)
        let canvasSize = CGSize(width: (shot.pointSize.width * fit).rounded(), height: (shot.pointSize.height * fit).rounded())

        let contentSize = CGSize(width: max(Self.minContentWidth, canvasSize.width + Self.padding * 2),
                                 height: canvasSize.height + Self.padding * 2 + Self.toolbarHeight)

        window = KeyableWindow(contentRect: CGRect(origin: .zero, size: contentSize),
                               styleMask: [.borderless],
                               backing: .buffered, defer: false)
        super.init()

        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.backgroundColor = .clear

        let root = EditorRootView(model: model, canvas: canvas, canvasSize: canvasSize,
                                  toolbarHeight: Self.toolbarHeight, padding: Self.padding)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: contentSize)

        let blur = NSVisualEffectView(frame: hosting.frame)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        blur.autoresizingMask = [.width, .height]
        hosting.autoresizingMask = [.width, .height]
        blur.addSubview(hosting)
        window.contentView = blur

        model.onCopy = { [weak self] in self?.copyAndClose() }
        model.onSave = { [weak self] in self?.save() }
        model.onClose = { [weak self] in self?.window.close() }
    }

    func present() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window.firstResponder === self.window else { return }
            self.window.makeFirstResponder(self.canvas)
        }

        // Window-level shortcuts: work no matter which view SwiftUI left focused.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            // While typing a text annotation, let the field editor own the keys (Esc there cancels the text).
            if self.window.firstResponder is NSTextView { return event }
            return self.canvas.handleShortcut(event) ? nil : event
        }
    }

    func writeSnapshot(to path: String) {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("window frame:", window.frame, "content:", view.bounds)
    }

    func discard() { window.close() }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        onClose?()
    }

    // MARK: Output

    private func finalBitmap() -> NSBitmapImageRep? {
        guard let cg = canvas.renderFinal() else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        // Full pixel data, tagged with the Retina point size so apps that honor DPI paste at true size, crisp.
        rep.size = shot.pointSize
        return rep
    }

    private func copyAndClose() {
        guard let rep = finalBitmap(), let png = rep.representation(using: .png, properties: [:]) else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = rep.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pb.writeObjects([item])
        window.close()
        Toast.show("Copied to clipboard", symbol: "checkmark.circle.fill")
    }

    private func save() {
        guard let rep = finalBitmap(), let png = rep.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue = "ShotX \(stamp.string(from: Date())).png"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try png.write(to: url)
                self?.window.close()
                Toast.show("Saved", symbol: "arrow.down.circle.fill")
            } catch {
                NSSound.beep()
            }
        }
    }
}

// MARK: - SwiftUI

private struct CanvasRepresentable: NSViewRepresentable {
    let canvas: CanvasView
    func makeNSView(context: Context) -> CanvasView { canvas }
    func updateNSView(_ nsView: CanvasView, context: Context) {}
}

private struct EditorRootView: View {
    @ObservedObject var model: EditorModel
    let canvas: CanvasView
    let canvasSize: CGSize
    let toolbarHeight: CGFloat
    let padding: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(model: model)
                .frame(height: toolbarHeight)
                .padding(.horizontal, padding)
            CanvasRepresentable(canvas: canvas)
                .frame(width: canvasSize.width, height: canvasSize.height)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.08)))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                .padding([.horizontal, .bottom], padding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .preferredColorScheme(.dark)
    }
}

private struct EditorToolbar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 10) {
            Button { model.onClose?() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Discard (Esc)")

            HStack(spacing: 2) {
                ForEach(Tool.allCases) { tool in
                    ToolButton(symbol: tool.symbol, selected: model.tool == tool,
                               help: "\(tool.label) (\(tool.shortcut.uppercased()))") { model.tool = tool }
                }
            }
            .modifier(Pill())

            StyleButton(model: model).modifier(Pill())

            HStack(spacing: 2) {
                ToolButton(symbol: "arrow.uturn.backward", selected: false, help: "Undo (⌘Z)") { model.undo() }
                    .disabled(!model.canUndo).opacity(model.canUndo ? 1 : 0.35)
                ToolButton(symbol: "arrow.uturn.forward", selected: false, help: "Redo (⇧⌘Z)") { model.redo() }
                    .disabled(!model.canRedo).opacity(model.canRedo ? 1 : 0.35)
            }
            .modifier(Pill())

            Spacer(minLength: 0)

            ToolButton(symbol: "square.and.arrow.down", selected: false, help: "Save as PNG (⌘S)") { model.onSave?() }

            Button { model.onCopy?() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard.fill").font(.system(size: 11, weight: .semibold))
                    Text("Copy").font(.system(size: 12, weight: .semibold))
                    Text("⏎").font(.system(size: 11, weight: .medium)).opacity(0.6)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(Color.accentColor.gradient))
                .shadow(color: Color.accentColor.opacity(0.4), radius: 6, y: 2)
                .fixedSize()
            }
            .buttonStyle(.plain)
            .help("Copy to clipboard (⏎ or ⌘C)")
        }
    }
}

private struct Pill: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.07)))
    }
}

/// Current color + stroke size; opens a popover with the full palette.
private struct StyleButton: View {
    @ObservedObject var model: EditorModel
    @State private var open = false
    @State private var hover = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color(nsColor: model.color))
                    .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                    .frame(width: 16, height: 16)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.6)
            }
            .foregroundStyle(.white)
            .frame(width: 42, height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(hover || open ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Color & size (1–8)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 8), count: 4), spacing: 8) {
                    ForEach(Array(Palette.colors.enumerated()), id: \.offset) { _, color in
                        ColorDot(color: color, selected: model.color == color) { model.color = color }
                    }
                }
                Divider().opacity(0.5)
                HStack(spacing: 4) {
                    ForEach(Palette.widths, id: \.self) { w in
                        Button { model.width = w } label: {
                            Circle().fill(.white.opacity(model.width == w ? 1 : 0.5))
                                .frame(width: w + 4, height: w + 4)
                                .frame(width: 32, height: 26)
                                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(model.width == w ? 0.16 : 0)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(12)
            .preferredColorScheme(.dark)
        }
    }
}

private struct ToolButton: View {
    let symbol: String
    let selected: Bool
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? Color.white : Color.white.opacity(hover ? 0.95 : 0.7))
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(selected ? Color.accentColor : Color.white.opacity(hover ? 0.1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .animation(.easeOut(duration: 0.12), value: selected)
    }
}

private struct ColorDot: View {
    let color: NSColor
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(nsColor: color))
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                .frame(width: 16, height: 16)
                .padding(2.5)
                .overlay(Circle().strokeBorder(.white, lineWidth: selected ? 2 : 0))
                .scaleEffect(selected ? 1.05 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: selected)
    }
}
