// Draws Dürücü's app icon and writes the AppIcon asset catalog set.
// Usage: swift scripts/make-icon.swift Durucu/Resources/Assets.xcassets/AppIcon.appiconset

import AppKit
import CoreGraphics

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: locations)!
}

/// macOS squircle: continuous-corner rounded rect.
func squircle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    return path.cgPath
}

func drawIcon(in ctx: CGContext, size: CGFloat) {
    let s = size / 1024
    ctx.scaleBy(x: s, y: s)

    // Tile with the standard macOS margins (824pt artwork on a 1024 canvas).
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = squircle(tile, radius: 186)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.28))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0xF26A3D))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([color(0xFFB45E), color(0xFF7A45), color(0xEE3F6C)], [0, 0.5, 1]),
        start: CGPoint(x: 160, y: 924), end: CGPoint(x: 860, y: 100), options: []
    )
    ctx.drawRadialGradient(
        gradient([color(0xFFFFFF, 0.35), color(0xFFFFFF, 0)], [0, 1]),
        startCenter: CGPoint(x: 300, y: 820), startRadius: 0,
        endCenter: CGPoint(x: 300, y: 820), endRadius: 520, options: []
    )
    ctx.restoreGState()

    // The sheet being rolled up.
    let sheet = CGRect(x: 292, y: 360, width: 440, height: 440)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x7A1A10, 0.35))
    ctx.addPath(CGPath(roundedRect: sheet, cornerWidth: 46, cornerHeight: 46, transform: nil))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: sheet, cornerWidth: 46, cornerHeight: 46, transform: nil))
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([color(0xFFFFFF), color(0xFFEDE3)], [0, 1]),
        start: CGPoint(x: 0, y: sheet.maxY), end: CGPoint(x: 0, y: sheet.minY), options: []
    )
    ctx.restoreGState()

    // Zipper teeth running down the sheet.
    let centerX: CGFloat = 512
    var y: CGFloat = 618
    var left = true
    while y > 430 {
        let tooth = CGRect(x: left ? centerX - 34 : centerX - 2, y: y, width: 36, height: 18)
        ctx.addPath(CGPath(roundedRect: tooth, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.setFillColor(color(0xF0603A))
        ctx.fillPath()
        y -= 26
        left.toggle()
    }

    // Zipper pull.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 8, color: color(0x7A1A10, 0.35))
    let slider = CGRect(x: centerX - 40, y: 742, width: 80, height: 40)
    ctx.addPath(CGPath(roundedRect: slider, cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.setFillColor(color(0xC8381F))
    ctx.fillPath()
    let tab = CGRect(x: centerX - 22, y: 640, width: 44, height: 110)
    ctx.addPath(CGPath(roundedRect: tab, cornerWidth: 22, cornerHeight: 22, transform: nil))
    ctx.setFillColor(color(0xD9452A))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(CGPath(roundedRect: CGRect(x: centerX - 9, y: 660, width: 18, height: 44), cornerWidth: 9, cornerHeight: 9, transform: nil))
    ctx.setFillColor(color(0xFFE3D6))
    ctx.fillPath()

    // The roll at the bottom (the "dürüm").
    let roll = CGRect(x: 236, y: 252, width: 552, height: 168)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 30, color: color(0x6A1208, 0.4))
    ctx.addPath(CGPath(roundedRect: roll, cornerWidth: 84, cornerHeight: 84, transform: nil))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: roll, cornerWidth: 84, cornerHeight: 84, transform: nil))
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([color(0xFFFFFF), color(0xFFF1EA), color(0xF6C9B6)], [0, 0.45, 1]),
        start: CGPoint(x: 0, y: roll.maxY), end: CGPoint(x: 0, y: roll.minY), options: []
    )
    ctx.restoreGState()

    // Spiral end of the roll.
    let spiralCenter = CGPoint(x: roll.minX + 84, y: roll.midY)
    ctx.addEllipse(in: CGRect(x: spiralCenter.x - 70, y: spiralCenter.y - 70, width: 140, height: 140))
    ctx.setFillColor(color(0xFFF6F1))
    ctx.fillPath()
    ctx.setLineCap(.round)
    for (index, radius) in [56.0, 40.0, 24.0].enumerated() {
        ctx.addArc(center: spiralCenter, radius: radius, startAngle: 0.3 + CGFloat(index) * 0.5, endAngle: .pi * 1.75 + CGFloat(index) * 0.5, clockwise: false)
        ctx.setStrokeColor(color(0xF0603A, 0.85 - CGFloat(index) * 0.15))
        ctx.setLineWidth(10)
        ctx.strokePath()
    }
    ctx.addEllipse(in: CGRect(x: spiralCenter.x - 7, y: spiralCenter.y - 7, width: 14, height: 14))
    ctx.setFillColor(color(0xF0603A))
    ctx.fillPath()

    // Highlight along the top of the roll.
    ctx.addPath(CGPath(roundedRect: CGRect(x: roll.minX + 170, y: roll.maxY - 40, width: 300, height: 14), cornerWidth: 7, cornerHeight: 7, transform: nil))
    ctx.setFillColor(color(0xFFFFFF, 0.9))
    ctx.fillPath()
}

func render(_ pixels: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    drawIcon(in: ctx, size: CGFloat(pixels))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for point in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(point)x\(point)\(scale == 2 ? "@2x" : "").png"
        try render(point * scale).write(to: output.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(point)x\(point)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: output.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(output.path)")
