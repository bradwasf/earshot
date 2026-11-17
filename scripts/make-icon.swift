#!/usr/bin/env swift
// Draws Earshot's app icon (the two-lane waveform on a sky-blue tile) as a 1024×1024 PNG.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.png
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

guard
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)
else { fatalError("could not create bitmap") }
NSGraphicsContext.current = graphics
let context = graphics.cgContext

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Tile: the standard macOS icon grid (824 pt tile on a 1024 pt canvas) with a soft drop shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x031B2B, 0.35))
context.addPath(shape)
context.setFillColor(color(0x0284C7))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(shape)
context.clip()
let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x56CBFB), color(0x0E94DA), color(0x0369A1)] as CFArray,
    locations: [0, 0.5, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// A faint sheen across the top third.
let sheen = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray,
    locations: [0, 1])!
context.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])
context.restoreGState()

// Two lanes of bars around a centre line: "Me" above (solid white), "Them" below (translucent).
let above: [CGFloat] = [0.30, 0.52, 0.86, 0.62, 1.00, 0.46, 0.74, 0.38, 0.24]
let below: [CGFloat] = [0.22, 0.40, 0.58, 0.92, 0.50, 0.80, 0.34, 0.60, 0.28]
let barWidth: CGFloat = 46
let gap: CGFloat = 24
let reach: CGFloat = 210
let middle: CGFloat = 512
let total = CGFloat(above.count) * barWidth + CGFloat(above.count - 1) * gap
var x = (size - total) / 2
for index in above.indices {
    let up = max(barWidth, reach * above[index])
    let down = max(barWidth, reach * below[index])
    let upper = CGRect(x: x, y: middle + 14, width: barWidth, height: up)
    let lower = CGRect(x: x, y: middle - 14 - down, width: barWidth, height: down)
    context.addPath(CGPath(roundedRect: upper, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    context.setFillColor(color(0xFFFFFF))
    context.fillPath()
    context.addPath(CGPath(roundedRect: lower, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    context.setFillColor(color(0xFFFFFF, 0.55))
    context.fillPath()
    x += barWidth + gap
}

graphics.flushGraphics()
guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("could not encode PNG") }
try png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
