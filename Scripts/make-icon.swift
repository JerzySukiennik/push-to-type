#!/usr/bin/env swift
//
// make-icon.swift — renders Resources/AppIcon.icns.
//
//   swift Scripts/make-icon.swift
//
// The mark is a microphone capsule with a text caret rising out of it: sound going in,
// text coming out. Drawn in code rather than shipped as a binary asset so it stays
// editable, diffable, and resolution-independent by construction.
//
import AppKit
import Foundation

/// Draws the icon at `size` points into a bitmap.
func renderIcon(size: CGFloat) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size),
        pixelsHigh: Int(size),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let unit = size / 1024  // all measurements are in 1024-point design units

    // Rounded-square plate, following Apple's 1024 → 824 content inset.
    let inset = 100 * unit
    let plate = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let plateRadius = 185 * unit

    NSColor(calibratedWhite: 0.09, alpha: 1).setFill()
    NSBezierPath(roundedRect: plate, xRadius: plateRadius, yRadius: plateRadius).fill()

    // Microphone capsule.
    let capsuleWidth = 190 * unit
    let capsuleHeight = 330 * unit
    let capsule = NSRect(
        x: size / 2 - capsuleWidth / 2 - 60 * unit,
        y: size / 2 - capsuleHeight / 2 + 95 * unit,
        width: capsuleWidth,
        height: capsuleHeight
    )
    NSColor.white.setFill()
    NSBezierPath(
        roundedRect: capsule,
        xRadius: capsuleWidth / 2,
        yRadius: capsuleWidth / 2
    ).fill()

    // The cradle: an arc under the capsule plus a short stem.
    let cradle = NSBezierPath()
    let cradleRadius = 165 * unit
    cradle.appendArc(
        withCenter: NSPoint(x: capsule.midX, y: capsule.minY + 30 * unit),
        radius: cradleRadius,
        startAngle: 200,
        endAngle: 340
    )
    cradle.lineWidth = 46 * unit
    cradle.lineCapStyle = .round
    NSColor.white.setStroke()
    cradle.stroke()

    // Stem: from the lowest point of the arc straight down.
    let cradleBottom = capsule.minY + 30 * unit - cradleRadius
    let stem = NSBezierPath()
    stem.move(to: NSPoint(x: capsule.midX, y: cradleBottom))
    stem.line(to: NSPoint(x: capsule.midX, y: cradleBottom - 105 * unit))
    stem.lineWidth = 46 * unit
    stem.lineCapStyle = .round
    stem.stroke()

    // Text caret to the right: what comes out.
    let caretWidth = 40 * unit
    let caretHeight = 300 * unit
    let caret = NSRect(
        x: capsule.maxX + 105 * unit,
        y: size / 2 - caretHeight / 2 + 40 * unit,
        width: caretWidth,
        height: caretHeight
    )
    NSColor(calibratedRed: 0.29, green: 0.66, blue: 1, alpha: 1).setFill()
    NSBezierPath(roundedRect: caret, xRadius: caretWidth / 2, yRadius: caretWidth / 2).fill()

    return rep
}

// MARK: - Iconset

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
let destination = root.appendingPathComponent("Resources/AppIcon.icns")

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// The sizes `iconutil` expects, as (points, scale) pairs.
let variants: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]

for variant in variants {
    let pixels = variant.points * variant.scale
    guard let rep = renderIcon(size: CGFloat(pixels)),
          let data = rep.representation(using: .png, properties: [:])
    else {
        FileHandle.standardError.write(Data("failed to render \(pixels)px\n".utf8))
        exit(1)
    }
    let suffix = variant.scale == 1 ? "" : "@2x"
    let name = "icon_\(variant.points)x\(variant.points)\(suffix).png"
    try data.write(to: iconset.appendingPathComponent(name))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", destination.path]
try iconutil.run()
iconutil.waitUntilExit()

guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

try? FileManager.default.removeItem(at: iconset)
print("Wrote \(destination.path)")
