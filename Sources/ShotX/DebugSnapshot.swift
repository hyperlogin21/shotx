import AppKit

/// `ShotX --snapshot-editor <out.png> [widthPt heightPt]`: opens the editor on a synthetic
/// Retina image and writes a picture of the window, for checking layout without capturing.
enum DebugSnapshot {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        // `--selftest-capture <out.txt>`: attempt a real capture and report the result (permission check).
        if let i = args.firstIndex(of: "--selftest-capture"), i + 1 < args.count {
            let out = args[i + 1]
            Task { @MainActor in
                var report: String
                do {
                    let shots = try await ScreenGrabber.captureAllScreens()
                    report = "OK: " + shots.map { "\($0.image.width)x\($0.image.height)@\($0.scale)x" }.joined(separator: ", ")
                } catch {
                    report = "FAILED: \(error.localizedDescription)"
                }
                try? report.write(toFile: out, atomically: true, encoding: .utf8)
                exit(0)
            }
            return true
        }
        guard let i = args.firstIndex(of: "--snapshot-editor"), i + 1 < args.count else { return false }
        let out = args[i + 1]
        let w = i + 2 < args.count ? Double(args[i + 2]) ?? 500 : 500
        let h = i + 3 < args.count ? Double(args[i + 3]) ?? 300 : 300

        let scale: CGFloat = 2
        let ctx = CGContext(data: nil, width: Int(w * scale), height: Int(h * scale), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w * scale, height: h * scale))
        let shot = CroppedShot(image: ctx.makeImage()!, scale: scale, screen: NSScreen.main!)

        let editor = EditorWindowController(shot: shot)
        editor.present()
        if args.contains("--test-move") {
            // Place a label, drag it with the text tool active, then undo.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                _ = editor
                let m = editor.model, c = editor.canvas
                m.tool = .text
                m.add(Annotation(tool: .text, color: .red, width: 4, points: [CGPoint(x: 50, y: 50)], text: "this is here"))
                let scale = c.bounds.width / shot.pointSize.width
                func ev(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, clicks: Int = 1) -> NSEvent {
                    // Canvas is flipped; convert image point -> window coords.
                    let local = CGPoint(x: x * scale, y: y * scale)
                    let win = c.convert(local, to: nil)
                    return NSEvent.mouseEvent(with: type, location: win, modifierFlags: [], timestamp: 0,
                                              windowNumber: c.window!.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
                }
                c.mouseDown(with: ev(.leftMouseDown, 60, 58))
                c.mouseDragged(with: ev(.leftMouseDragged, 110, 88))
                c.mouseDragged(with: ev(.leftMouseDragged, 160, 108))
                c.mouseUp(with: ev(.leftMouseUp, 160, 108))
                let moved = m.annotations.map(\.start)
                let fieldOpened = c.subviews.contains { $0 is NSTextField }
                m.undo()
                print("count:", m.annotations.count, "after move:", moved, "text field opened:", fieldOpened, "after undo:", m.annotations.map(\.start))
                // Double-click should open the label for editing with its text.
                c.mouseDown(with: ev(.leftMouseDown, 60, 58, clicks: 2))
                let field = c.subviews.compactMap { $0 as? NSTextField }.first
                print("double-click edit field text:", field?.stringValue ?? "none")
                c.commitText()
                c.mouseDown(with: ev(.leftMouseDown, 60, 58))
                c.mouseUp(with: ev(.leftMouseUp, 60, 58))
                print("selected:", c.selectedIndex as Any)
                c.display()
                editor.writeSnapshot(to: out)
                if let tiff = NSCursor.move.image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + ".cursor.png"))
                }
                exit(0)
            }
            return true
        }
        if args.contains("--press-esc") {
            // Simulate Esc and report whether the editor dismissed itself.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil,
                                           characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
                NSApp.postEvent(esc, atStart: true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                _ = editor // keep alive, as AppDelegate.editors does in the real app
                print("editor visible after Esc:", NSApp.windows.contains { $0.isVisible && $0 is KeyableWindow })
                exit(0)
            }
            return true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            editor.writeSnapshot(to: out)
            exit(0)
        }
        return true
    }
}
