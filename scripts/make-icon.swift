// Builds Resources/AppIcon.png (1024×1024) from a square source icon:
// recolors it by rotating the hue, upscales it and masks it to the macOS squircle grid.
//   swift scripts/make-icon.swift <source.png|webp> Resources/AppIcon.png [hue shift in degrees, default 70]
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: make-icon <source> <out.png> [hueDegrees]"); exit(1) }
let hueShift = args.count > 3 ? Double(args[3]) ?? 70 : 70 // 70° turns the source teal (~166°) into indigo (~236°)

guard let src = CIImage(contentsOf: URL(fileURLWithPath: args[1])) else { fatalError("cannot read \(args[1])") }

// Recolor: white stays white, every tint of the accent colour shifts together.
// Hue rotation washes the colour out a little; saturation + gamma bring the depth back (white stays white).
let recolored = src
    .applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: hueShift * .pi / 180])
    .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35])
    .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1.25])

// Apple's icon grid: 824×824 artwork centred in a 1024 canvas.
let canvas = 1024.0, art = 824.0, margin = (canvas - art) / 2
let scale = art / src.extent.width
let scaled = recolored
    .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
    .transformed(by: CGAffineTransform(translationX: margin, y: margin))

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ci = CIContext(options: [.workingColorSpace: space])
guard let artImage = ci.createCGImage(scaled, from: CGRect(x: margin, y: margin, width: art, height: art)) else { fatalError("render failed") }

/// macOS icon outline: superellipse, n = 5.
func squircle(_ r: CGRect, n: Double = 5) -> CGPath {
    let p = CGMutablePath()
    for i in 0...720 {
        let t = Double(i) / 720 * 2 * .pi, c = cos(t), s = sin(t)
        let pt = CGPoint(x: r.midX + r.width / 2 * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n),
                         y: r.midY + r.height / 2 * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n))
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    p.closeSubpath()
    return p
}

let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
let rect = CGRect(x: margin, y: margin, width: art, height: art)
let shape = squircle(rect)
ctx.saveGState() // soft drop shadow like other Mac app icons
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.3))
ctx.addPath(shape); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
ctx.restoreGState()
ctx.addPath(shape); ctx.clip()
ctx.draw(artImage, in: rect)

let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(args[2])") }
print("wrote \(args[2]) (hue shift \(Int(hueShift))°)")
