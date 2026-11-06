import AppKit
import ScreenCaptureKit

struct ScreenShot {
    let screen: NSScreen
    let image: CGImage
    let scale: CGFloat
}

struct CroppedShot {
    let image: CGImage
    /// Pixels per point of the source display.
    let scale: CGFloat
    let screen: NSScreen
    var pointSize: CGSize { CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }
}

enum ScreenGrabber {
    /// Freezes every connected display at native resolution.
    @MainActor
    static func captureAllScreens() async throws -> [ScreenShot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var shots: [ScreenShot] = []

        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == number }) else { continue }

            let scale = screen.backingScaleFactor
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * scale)
            config.height = Int(screen.frame.height * scale)
            config.showsCursor = false
            config.captureResolution = .best          // native Retina pixels, never downsampled
            config.colorSpaceName = CGColorSpace.sRGB  // consistent colors wherever it's pasted
            config.scalesToFit = false

            // Never capture our own editor/toast windows.
            let ownWindows = content.windows.filter { $0.owningApplication?.processID == getpid() }
            let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            shots.append(ScreenShot(screen: screen, image: image, scale: scale))
        }
        return shots
    }
}
