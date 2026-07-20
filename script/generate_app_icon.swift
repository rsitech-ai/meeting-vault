#!/usr/bin/env swift
import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Sources/MeetingVault/Resources", isDirectory: true)
let iconset = resources.appendingPathComponent("MeetingVault.iconset", isDirectory: true)
let output = resources.appendingPathComponent("MeetingVault.icns")

try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

struct IconTarget {
    var points: Int
    var scale: Int

    var pixels: Int { points * scale }
    var filename: String {
        scale == 1
            ? "icon_\(points)x\(points).png"
            : "icon_\(points)x\(points)@\(scale)x.png"
    }
}

let targets = [
    IconTarget(points: 16, scale: 1),
    IconTarget(points: 16, scale: 2),
    IconTarget(points: 32, scale: 1),
    IconTarget(points: 32, scale: 2),
    IconTarget(points: 128, scale: 1),
    IconTarget(points: 128, scale: 2),
    IconTarget(points: 256, scale: 1),
    IconTarget(points: 256, scale: 2),
    IconTarget(points: 512, scale: 1),
    IconTarget(points: 512, scale: 2)
]

func drawIcon(size: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    rect.fill()

    let inset = CGFloat(size) * 0.055
    let body = rect.insetBy(dx: inset, dy: inset)
    let radius = CGFloat(size) * 0.215
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    NSGraphicsContext.current?.saveGraphicsState()
    bodyPath.addClip()

    NSGradient(colors: [
        NSColor(calibratedRed: 0.07, green: 0.13, blue: 0.22, alpha: 1),
        NSColor(calibratedRed: 0.08, green: 0.34, blue: 0.44, alpha: 1),
        NSColor(calibratedRed: 0.42, green: 0.23, blue: 0.76, alpha: 1)
    ])?.draw(in: body, angle: 42)

    let glow = NSBezierPath(ovalIn: body.insetBy(dx: -CGFloat(size) * 0.18, dy: CGFloat(size) * 0.38))
    NSColor(calibratedRed: 0.30, green: 0.94, blue: 0.82, alpha: 0.32).setFill()
    glow.fill()

    let lowerGlow = NSBezierPath(ovalIn: body.offsetBy(dx: CGFloat(size) * 0.18, dy: -CGFloat(size) * 0.43))
    NSColor(calibratedRed: 0.92, green: 0.43, blue: 0.70, alpha: 0.22).setFill()
    lowerGlow.fill()

    NSGraphicsContext.current?.restoreGraphicsState()

    NSColor(calibratedWhite: 1, alpha: 0.22).setStroke()
    bodyPath.lineWidth = max(1, CGFloat(size) * 0.015)
    bodyPath.stroke()

    let vaultRect = NSRect(
        x: CGFloat(size) * 0.235,
        y: CGFloat(size) * 0.205,
        width: CGFloat(size) * 0.53,
        height: CGFloat(size) * 0.44
    )
    let vaultPath = NSBezierPath(roundedRect: vaultRect, xRadius: CGFloat(size) * 0.085, yRadius: CGFloat(size) * 0.085)
    NSColor(calibratedWhite: 0.98, alpha: 0.20).setFill()
    vaultPath.fill()
    NSColor(calibratedWhite: 1, alpha: 0.58).setStroke()
    vaultPath.lineWidth = max(1.5, CGFloat(size) * 0.026)
    vaultPath.stroke()

    let dial = NSBezierPath(ovalIn: NSRect(
        x: CGFloat(size) * 0.415,
        y: CGFloat(size) * 0.345,
        width: CGFloat(size) * 0.17,
        height: CGFloat(size) * 0.17
    ))
    NSColor(calibratedRed: 0.57, green: 0.95, blue: 0.90, alpha: 0.92).setFill()
    dial.fill()
    NSColor(calibratedWhite: 1, alpha: 0.78).setStroke()
    dial.lineWidth = max(1, CGFloat(size) * 0.012)
    dial.stroke()

    let waveform = NSBezierPath()
    let midY = CGFloat(size) * 0.735
    let startX = CGFloat(size) * 0.245
    let step = CGFloat(size) * 0.055
    waveform.move(to: NSPoint(x: startX, y: midY))
    for index in 0..<10 {
        let x = startX + CGFloat(index + 1) * step
        let amplitude = CGFloat(index % 2 == 0 ? 1 : -1) * CGFloat(size) * (index == 4 || index == 5 ? 0.105 : 0.065)
        waveform.line(to: NSPoint(x: x, y: midY + amplitude))
    }
    NSColor(calibratedRed: 0.64, green: 1.0, blue: 0.91, alpha: 0.95).setStroke()
    waveform.lineCapStyle = .round
    waveform.lineJoinStyle = .round
    waveform.lineWidth = max(2, CGFloat(size) * 0.028)
    waveform.stroke()

    let shadow = NSBezierPath(roundedRect: body.insetBy(dx: CGFloat(size) * 0.03, dy: CGFloat(size) * 0.03), xRadius: radius * 0.86, yRadius: radius * 0.86)
    NSColor(calibratedWhite: 0, alpha: 0.16).setStroke()
    shadow.lineWidth = max(1, CGFloat(size) * 0.018)
    shadow.stroke()

    return image
}

for target in targets {
    let image = drawIcon(size: target.pixels)
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "MeetingVaultIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode \(target.filename)"])
    }
    try png.write(to: iconset.appendingPathComponent(target.filename), options: .atomic)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()

if process.terminationStatus != 0 {
    throw NSError(domain: "MeetingVaultIcon", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
}

print(output.path)
