// Draws the app icon (1024×1024 PNG) with Core Graphics.
//   swift scripts/generate-icon.swift Resources/AppIcon.png
// Original artwork: a 360° lens with a globe grid and an orbit arrow on a macOS-style squircle.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let space = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat(hex >> 16 & 0xFF) / 255, CGFloat(hex >> 8 & 0xFF) / 255,
                                           CGFloat(hex & 0xFF) / 255, a])!
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

/// macOS icon shape: a superellipse ("squircle") on Apple's 824-pt grid inside the 1024 canvas.
func squircle(_ rect: CGRect, n: Double = 5) -> CGPath {
    let p = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2, cx = rect.midX, cy = rect.midY
    for i in 0...720 {
        let t = Double(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = squircle(body)
let center = CGPoint(x: 512, y: 512)

// Drop shadow + background gradient (deep indigo → electric blue).
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(shape); ctx.setFillColor(rgb(0x1B1F5E)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0x5B3DF5), rgb(0x2446D8), rgb(0x0B1E6B)], [0, 0.55, 1]),
                       start: CGPoint(x: 180, y: 924), end: CGPoint(x: 844, y: 100), options: [])
// Soft top glow.
ctx.drawRadialGradient(gradient([rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)], [0, 1]),
                       startCenter: CGPoint(x: 512, y: 900), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 900), endRadius: 520, options: [])
ctx.restoreGState()

// Orbit ring behind the lens (back half), tilted ellipse.
let orbitW = 700.0, orbitH = 230.0, tilt = -18.0 * .pi / 180
func orbitPath(from a0: Double, to a1: Double) -> CGPath {
    let p = CGMutablePath()
    var t = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: tilt)
    let steps = 200
    for i in 0...steps {
        let a = a0 + (a1 - a0) * Double(i) / Double(steps)
        let pt = CGPoint(x: orbitW / 2 * cos(a), y: orbitH / 2 * sin(a))
        i == 0 ? p.move(to: pt, transform: t) : p.addLine(to: pt, transform: t)
    }
    _ = t
    t = .identity
    return p
}
ctx.setLineCap(.round)
ctx.addPath(orbitPath(from: 0.05 * .pi, to: 0.95 * .pi))
ctx.setStrokeColor(rgb(0x9FE8FF, 0.45)); ctx.setLineWidth(22); ctx.strokePath()

// Lens housing: white ring with soft shadow.
let housingR = 250.0
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x000000, 0.35))
ctx.addEllipse(in: CGRect(x: center.x - housingR, y: center.y - housingR, width: housingR * 2, height: housingR * 2))
ctx.setFillColor(rgb(0xF4F7FF)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: center.x - housingR, y: center.y - housingR, width: housingR * 2, height: housingR * 2))
ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0xFFFFFF), rgb(0xD5DDF5)], [0, 1]),
                       start: CGPoint(x: 512, y: 762), end: CGPoint(x: 512, y: 262), options: [])
ctx.restoreGState()

// Glass: dark sphere with globe grid.
let glassR = 180.0
let glassRect = CGRect(x: center.x - glassR, y: center.y - glassR, width: glassR * 2, height: glassR * 2)
ctx.saveGState()
ctx.addEllipse(in: glassRect); ctx.clip()
ctx.drawRadialGradient(gradient([rgb(0x2C5BFF, 0.9), rgb(0x10205E), rgb(0x050A24)], [0, 0.55, 1]),
                       startCenter: CGPoint(x: 470, y: 560), startRadius: 0,
                       endCenter: center, endRadius: glassR, options: [.drawsAfterEndLocation])
ctx.setStrokeColor(rgb(0x7FD6FF, 0.55)); ctx.setLineWidth(6)
for k in [-2.0, -1, 0, 1, 2] { // meridians
    let w = glassR * cos(k * .pi / 6) * 2
    ctx.addEllipse(in: CGRect(x: center.x - w / 2, y: center.y - glassR, width: w, height: glassR * 2))
}
for k in [-2.0, -1, 0, 1, 2] { // parallels
    let lat = k * .pi / 7.5
    let y = center.y + glassR * sin(lat), half = glassR * cos(lat)
    ctx.move(to: CGPoint(x: center.x - half, y: y)); ctx.addLine(to: CGPoint(x: center.x + half, y: y))
}
ctx.strokePath()
ctx.restoreGState()
// Glass rim.
ctx.addEllipse(in: glassRect.insetBy(dx: -6, dy: -6))
ctx.setStrokeColor(rgb(0x1A2A6C)); ctx.setLineWidth(14); ctx.strokePath()
// Specular highlights.
ctx.addEllipse(in: CGRect(x: 418, y: 572, width: 74, height: 74)); ctx.setFillColor(rgb(0xFFFFFF, 0.9)); ctx.fillPath()
ctx.addEllipse(in: CGRect(x: 505, y: 548, width: 30, height: 30)); ctx.setFillColor(rgb(0xFFFFFF, 0.75)); ctx.fillPath()

// Orbit ring front half with arrowhead.
ctx.addPath(orbitPath(from: 1.08 * .pi, to: 1.88 * .pi))
ctx.setStrokeColor(rgb(0x9FE8FF)); ctx.setLineWidth(26); ctx.strokePath()
let tipAngle = 1.93 * Double.pi
let rot = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: tilt)
let tip = CGPoint(x: orbitW / 2 * cos(tipAngle), y: orbitH / 2 * sin(tipAngle)).applying(rot)
let dir = atan2(orbitH / 2 * cos(tipAngle), -orbitW / 2 * sin(tipAngle)) + tilt
let arrow = CGMutablePath()
arrow.move(to: CGPoint(x: 34, y: 0))
arrow.addLine(to: CGPoint(x: -30, y: 42))
arrow.addLine(to: CGPoint(x: -30, y: -42))
arrow.closeSubpath()
ctx.addPath(arrow.copy(using: [CGAffineTransform(rotationAngle: dir).concatenating(CGAffineTransform(translationX: tip.x, y: tip.y))])!)
ctx.setFillColor(rgb(0x9FE8FF)); ctx.fillPath()

let img = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(out)") }
print("wrote \(out)")
