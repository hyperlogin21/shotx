import AppKit
import CoreImage

enum Tool: String, CaseIterable, Identifiable {
    case arrow, rectangle, ellipse, pen, highlighter, text, counter, pixelate
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .pen: "scribble"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .counter: "1.circle"
        case .pixelate: "checkerboard.rectangle"
        }
    }

    var label: String {
        switch self {
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .text: "Text"
        case .counter: "Step Number"
        case .pixelate: "Pixelate"
        }
    }

    var shortcut: Character {
        switch self {
        case .arrow: "a"
        case .rectangle: "r"
        case .ellipse: "o"
        case .pen: "p"
        case .highlighter: "h"
        case .text: "t"
        case .counter: "n"
        case .pixelate: "b"
        }
    }
}

struct Annotation {
    var tool: Tool
    var color: NSColor
    var width: CGFloat
    var points: [CGPoint]
    var text: String = ""
    var number: Int = 0

    var start: CGPoint { points.first ?? .zero }
    var end: CGPoint { points.last ?? .zero }
    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    var fontSize: CGFloat { 10 + width * 3 }
    var font: NSFont { NSFont.systemFont(ofSize: fontSize, weight: .bold) }
}

/// Draws the screenshot plus annotations. Expects a flipped (top-left origin) context in image points.
struct Renderer {
    let base: CGImage
    let pixelated: CGImage?
    let size: CGSize

    static func makePixelated(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let ci = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(max(10 * scale, CGFloat(max(image.width, image.height)) / 90), forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        guard let out = filter.outputImage?.cropped(to: ci.extent) else { return nil }
        return CIContext(options: nil).createCGImage(out, from: ci.extent)
    }

    func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    func drawAll(_ annotations: [Annotation], ctx: CGContext) {
        drawImage(base, in: CGRect(origin: .zero, size: size), ctx: ctx)
        // Pixelation first so other markup stays legible on top of it.
        for a in annotations where a.tool == .pixelate { draw(a, ctx: ctx) }
        for a in annotations where a.tool != .pixelate { draw(a, ctx: ctx) }
    }

    func draw(_ a: Annotation, ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.setLineWidth(a.width)

        let shadow = { ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: NSColor.black.withAlphaComponent(0.35).cgColor) }

        switch a.tool {
        case .arrow:
            shadow()
            drawArrow(from: a.start, to: a.end, width: a.width, ctx: ctx)

        case .rectangle:
            shadow()
            ctx.addPath(CGPath(roundedRect: a.rect, cornerWidth: min(4, a.rect.width / 2), cornerHeight: min(4, a.rect.height / 2), transform: nil))
            ctx.strokePath()

        case .ellipse:
            shadow()
            ctx.strokeEllipse(in: a.rect)

        case .pen:
            shadow()
            strokeSmooth(a.points, ctx: ctx)

        case .highlighter:
            ctx.setBlendMode(.multiply)
            ctx.setStrokeColor(a.color.withAlphaComponent(0.45).cgColor)
            ctx.setLineWidth(a.width * 5)
            ctx.setLineCap(.square)
            strokeSmooth(a.points, ctx: ctx)

        case .text:
            shadow()
            let attrs: [NSAttributedString.Key: Any] = [.font: a.font, .foregroundColor: a.color]
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSAttributedString(string: a.text, attributes: attrs).draw(at: a.start)
            NSGraphicsContext.restoreGraphicsState()

        case .counter:
            let r = 9 + a.width * 2
            let circle = CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2)
            shadow()
            ctx.fillEllipse(in: circle)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(NSColor.white.cgColor)
            let ring = max(1.5, r * 0.12)
            ctx.setLineWidth(ring)
            ctx.strokeEllipse(in: circle.insetBy(dx: ring / 2, dy: ring / 2))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: r * 1.05, weight: .heavy),
                .foregroundColor: a.color.isLight ? NSColor.black : NSColor.white,
            ]
            let str = NSAttributedString(string: "\(a.number)", attributes: attrs)
            let s = str.size()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            str.draw(at: CGPoint(x: a.start.x - s.width / 2, y: a.start.y - s.height / 2))
            NSGraphicsContext.restoreGraphicsState()

        case .pixelate:
            guard let pixelated else { return }
            ctx.clip(to: a.rect)
            drawImage(pixelated, in: CGRect(origin: .zero, size: size), ctx: ctx)
        }
    }

    private func drawArrow(from p0: CGPoint, to p1: CGPoint, width: CGFloat, ctx: CGContext) {
        let dx = p1.x - p0.x, dy = p1.y - p0.y
        let len = hypot(dx, dy)
        guard len > 1 else { return }
        let angle = atan2(dy, dx)
        let headLen = min(len * 0.6, 10 + width * 3.5)
        let headHalf = headLen * 0.55

        let ux = cos(angle), uy = sin(angle)
        let base = CGPoint(x: p1.x - ux * headLen * 0.8, y: p1.y - uy * headLen * 0.8)
        let back = CGPoint(x: p1.x - ux * headLen, y: p1.y - uy * headLen)
        let left = CGPoint(x: back.x - uy * headHalf, y: back.y + ux * headHalf)
        let right = CGPoint(x: back.x + uy * headHalf, y: back.y - ux * headHalf)

        // Tapered shaft: thin at the tail, full width at the head.
        let tailHalf = width * 0.25, headShaftHalf = width * 0.6
        let path = CGMutablePath()
        path.move(to: CGPoint(x: p0.x - uy * tailHalf, y: p0.y + ux * tailHalf))
        path.addLine(to: CGPoint(x: base.x - uy * headShaftHalf, y: base.y + ux * headShaftHalf))
        path.addLine(to: left)
        path.addLine(to: p1)
        path.addLine(to: right)
        path.addLine(to: CGPoint(x: base.x + uy * headShaftHalf, y: base.y - ux * headShaftHalf))
        path.addLine(to: CGPoint(x: p0.x + uy * tailHalf, y: p0.y - ux * tailHalf))
        path.addArc(center: p0, radius: tailHalf, startAngle: angle - .pi / 2, endAngle: angle + .pi / 2, clockwise: false)
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setLineWidth(max(1, width * 0.3))
        ctx.drawPath(using: .fillStroke)
    }

    /// Quadratic smoothing through midpoints for natural-looking freehand strokes.
    private func strokeSmooth(_ pts: [CGPoint], ctx: CGContext) {
        guard let first = pts.first else { return }
        let path = CGMutablePath()
        path.move(to: first)
        if pts.count < 3 {
            pts.dropFirst().forEach { path.addLine(to: $0) }
            if pts.count == 1 { path.addLine(to: first) }
        } else {
            for i in 1..<pts.count - 1 {
                let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
                path.addQuadCurve(to: mid, control: pts[i])
            }
            path.addLine(to: pts[pts.count - 1])
        }
        ctx.addPath(path)
        ctx.strokePath()
    }

    /// Renders the final image at native pixel resolution.
    func export(_ annotations: [Annotation], pixelScale: CGFloat) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(base.height))
        ctx.scaleBy(x: pixelScale, y: -pixelScale)
        drawAll(annotations, ctx: ctx)
        return ctx.makeImage()
    }
}

extension NSColor {
    var isLight: Bool {
        guard let c = usingColorSpace(.sRGB) else { return false }
        return (0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent) > 0.7
    }
}
