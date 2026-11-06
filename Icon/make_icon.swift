// Renders ShotX's app icon. Usage: swift Icon/make_icon.swift <out.png> [size]
import AppKit

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "icon.png"
let S = CGFloat(args.count > 2 ? Double(args[2])! : 1024)
let k = S / 1024 // all geometry below is on Apple's 1024 grid

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: k, y: k)
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// Continuous-curvature squircle (superellipse), like macOS icon shapes.
func squircle(_ r: CGRect, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath()
    let a = r.width / 2, b = r.height / 2, c = CGPoint(x: r.midX, y: r.midY)
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = c.x + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
        let y = c.y + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = squircle(tile)

// Drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(shape); ctx.setFillColor(rgb(0x1E1B4B)); ctx.fillPath()
ctx.restoreGState()

// Background gradient
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x6D5BFF), rgb(0x3B2FC9), rgb(0x16123F)] as CFArray, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 220, y: 924), end: CGPoint(x: 820, y: 100), options: [])
// Soft top glow
let glow = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 380, y: 900), startRadius: 0, endCenter: CGPoint(x: 380, y: 900), endRadius: 560, options: [])
ctx.restoreGState()

// Inner rim highlight
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
ctx.addPath(squircle(tile.insetBy(dx: 2, dy: 2))); ctx.setStrokeColor(rgb(0xFFFFFF, 0.18)); ctx.setLineWidth(4); ctx.strokePath()
ctx.restoreGState()

// Viewfinder corner brackets
let frame = CGRect(x: 262, y: 262, width: 500, height: 500)
let arm: CGFloat = 132, rad: CGFloat = 54
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: rgb(0x0B0827, 0.45))
ctx.setStrokeColor(rgb(0xFFFFFF))
ctx.setLineWidth(44); ctx.setLineCap(.round); ctx.setLineJoin(.round)
for (cx, cy, sx, sy) in [(frame.minX, frame.minY, 1.0, 1.0), (frame.maxX, frame.minY, -1.0, 1.0),
                         (frame.minX, frame.maxY, 1.0, -1.0), (frame.maxX, frame.maxY, -1.0, -1.0)] {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: cx, y: cy + sy * arm))
    p.addArc(tangent1End: CGPoint(x: cx, y: cy), tangent2End: CGPoint(x: cx + sx * arm, y: cy), radius: rad)
    p.addLine(to: CGPoint(x: cx + sx * arm, y: cy))
    ctx.addPath(p)
}
ctx.strokePath()
ctx.restoreGState()

// Tapered annotation arrow (same style as the editor's arrow tool)
let p0 = CGPoint(x: 380, y: 380), p1 = CGPoint(x: 644, y: 644)
let width: CGFloat = 66
let angle = atan2(p1.y - p0.y, p1.x - p0.x), ux = cos(angle), uy = sin(angle)
let headLen: CGFloat = 176, headHalf = headLen * 0.66
let base = CGPoint(x: p1.x - ux * headLen * 0.7, y: p1.y - uy * headLen * 0.7)
let back = CGPoint(x: p1.x - ux * headLen, y: p1.y - uy * headLen)
let tailHalf = width * 0.28, shaftHalf = width * 0.5
let arrow = CGMutablePath()
arrow.move(to: CGPoint(x: p0.x - uy * tailHalf, y: p0.y + ux * tailHalf))
arrow.addLine(to: CGPoint(x: base.x - uy * shaftHalf, y: base.y + ux * shaftHalf))
arrow.addLine(to: CGPoint(x: back.x - uy * headHalf, y: back.y + ux * headHalf))
arrow.addLine(to: p1)
arrow.addLine(to: CGPoint(x: back.x + uy * headHalf, y: back.y - ux * headHalf))
arrow.addLine(to: CGPoint(x: base.x + uy * shaftHalf, y: base.y - ux * shaftHalf))
arrow.addLine(to: CGPoint(x: p0.x + uy * tailHalf, y: p0.y - ux * tailHalf))
arrow.addArc(center: p0, radius: tailHalf, startAngle: angle - .pi / 2, endAngle: angle + .pi / 2, clockwise: true)
arrow.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 30, color: rgb(0xFF3B5C, 0.55))
ctx.addPath(arrow); ctx.setFillColor(rgb(0xFF5A5F)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(arrow); ctx.clip()
let warm = CGGradient(colorsSpace: cs, colors: [rgb(0xFF8A5B), rgb(0xFF3B6B)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(warm, start: p1, end: p0, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()
ctx.addPath(arrow); ctx.setStrokeColor(rgb(0xFFFFFF, 0.35)); ctx.setLineWidth(3); ctx.setLineJoin(.round); ctx.strokePath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
