import AppKit
import SwiftUI

/// Small non-activating HUD confirming the copy.
enum Toast {
    private static var panel: NSPanel?

    static func show(_ message: String, symbol: String) {
        panel?.orderOut(nil)

        let view = NSHostingView(rootView:
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(.green).font(.system(size: 15, weight: .semibold))
                Text(message).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
            .environment(\.colorScheme, .dark)
            .padding(10)
        )
        let size = view.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        let origin = CGPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 80)

        let p = NSPanel(contentRect: CGRect(origin: origin, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = view
        p.alphaValue = 0
        p.orderFrontRegardless()
        panel = p

        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; p.animator().alphaValue = 0 }) {
                p.orderOut(nil)
                if panel === p { panel = nil }
            }
        }
    }
}
