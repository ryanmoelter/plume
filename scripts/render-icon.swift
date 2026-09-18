#!/usr/bin/env swift
// Renders a built Plume.app's icon to a 1024px PNG for the README.
//
// The .icon bundle only holds the feather glyph; the gradient, translucency and
// shadow are composed by macOS, and the compiled .icns stops at 256px. Asking
// NSWorkspace for the icon is the one path that yields the full treatment at
// any size.
//
// Usage: scripts/render-icon.swift out/Plume.app docs/images/plume-icon.png
import AppKit

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: render-icon.swift <Plume.app> <out.png>\n".utf8))
    exit(2)
}
let app = CommandLine.arguments[1], out = CommandLine.arguments[2]
let pixels = 1024

let icon = NSWorkspace.shared.icon(forFile: app)
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: out))
