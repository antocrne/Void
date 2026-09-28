#!/usr/bin/env swift
// Generates Void's app icon (all macOS sizes) into Assets.xcassets/AppIcon.appiconset.
// Usage: swift scripts/make-icon.swift
import AppKit
import CoreGraphics

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Void/Resources/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // macOS icon grid: 824/1024 body with ~185/1024 corner radius.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = body.width * 0.225
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Soft drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: color(0x000000, 0.45))
    ctx.addPath(path); ctx.setFillColor(color(0x0B0B0E)); ctx.fillPath()
    ctx.restoreGState()

    // Background: deep night gradient.
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [color(0x1B1A26), color(0x07070A)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])

    // Faint violet glow behind the eclipse.
    let center = CGPoint(x: s / 2, y: s / 2)
    let glow = CGGradient(colorsSpace: space, colors: [color(0x7B6CFF, 0.35), color(0x7B6CFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: body.width * 0.48, options: [])

    // Luminous disc (the corona).
    let r = body.width * 0.285
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
    ctx.clip()
    let corona = CGGradient(colorsSpace: space, colors: [color(0xF6F3FF), color(0xA597FF), color(0x4B3FD0)] as CFArray, locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(corona, start: CGPoint(x: center.x - r, y: center.y - r), end: CGPoint(x: center.x + r, y: center.y + r), options: [])
    ctx.restoreGState()

    // The void: dark disc, offset up-right, leaving a crescent of light.
    let vr = r * 0.88
    let offset = r * 0.105
    ctx.addEllipse(in: CGRect(x: center.x - vr + offset, y: center.y - vr + offset, width: 2 * vr, height: 2 * vr))
    ctx.setFillColor(color(0x07070A))
    ctx.fillPath()
    ctx.restoreGState()

    // Hairline highlight on the edge.
    ctx.addPath(path)
    ctx.setStrokeColor(color(0xFFFFFF, 0.08))
    ctx.setLineWidth(max(1, s * 0.004))
    ctx.strokePath()

    let image = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! render(px).write(to: output.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: output.appendingPathComponent("Contents.json"))
print("Icon written to \(output.path)")
