#!/usr/bin/env swift

import AppKit

// Deterministic artwork for the mounted installer window. Finder places the
// real app and Applications icons over this image, so the background only owns
// the instruction, direction, and small trust details.

private let canvas = NSSize(width: 680, height: 420)
private let outputPath = CommandLine.arguments.dropFirst().first ?? "dmg-background.png"

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha
        )
    }
}

private func drawCentered(
    _ text: String,
    y: CGFloat,
    font: NSFont,
    color: NSColor,
    tracking: CGFloat = 0
) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .kern: tracking,
    ]
    let string = NSAttributedString(string: text, attributes: attributes)
    let size = string.size()
    string.draw(at: NSPoint(x: (canvas.width - size.width) / 2, y: y))
}

private func drawPulseArrow(y: CGFloat) {
    let accent = NSColor(hex: 0xcaff58)

    let path = NSBezierPath()
    path.move(to: NSPoint(x: 257, y: y))
    path.line(to: NSPoint(x: 297, y: y))
    path.line(to: NSPoint(x: 310, y: y - 18))
    path.line(to: NSPoint(x: 325, y: y + 22))
    path.line(to: NSPoint(x: 340, y: y - 5))
    path.line(to: NSPoint(x: 351, y: y))
    path.line(to: NSPoint(x: 420, y: y))
    path.lineCapStyle = .round
    path.lineJoinStyle = .round

    accent.withAlphaComponent(0.11).setStroke()
    path.lineWidth = 12
    path.stroke()

    accent.setStroke()
    path.lineWidth = 3
    path.stroke()

    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 408, y: y - 11))
    arrow.line(to: NSPoint(x: 421, y: y))
    arrow.line(to: NSPoint(x: 408, y: y + 11))
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    accent.withAlphaComponent(0.14).setStroke()
    arrow.lineWidth = 10
    arrow.stroke()
    accent.setStroke()
    arrow.lineWidth = 3
    arrow.stroke()
}

private func drawLabelPlate(x: CGFloat, width: CGFloat) {
    let rect = NSRect(x: x, y: 298, width: width, height: 32)
    let plate = NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = 8
    shadow.shadowOffset = NSSize(width: 0, height: 2)
    shadow.set()
    NSColor(hex: 0xf0eee7, alpha: 0.94).setFill()
    plate.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSColor.white.withAlphaComponent(0.10).setStroke()
    plate.lineWidth = 1
    plate.stroke()
}

let image = NSImage(size: canvas)
image.lockFocusFlipped(true)

guard let context = NSGraphicsContext.current?.cgContext else {
    fatalError("Could not create the drawing context")
}

let fullRect = NSRect(origin: .zero, size: canvas)
let background = NSGradient(colors: [NSColor(hex: 0x151a15), NSColor(hex: 0x0b0f0c)])!
background.draw(in: fullRect, angle: 90)

// A restrained pool of charge behind the drag gesture.
context.saveGState()
let glowColors = [
    NSColor(hex: 0xcaff58, alpha: 0.13).cgColor,
    NSColor(hex: 0xcaff58, alpha: 0).cgColor,
] as CFArray
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glowColors, locations: [0, 1])!
context.drawRadialGradient(
    glow,
    startCenter: CGPoint(x: 340, y: 225),
    startRadius: 0,
    endCenter: CGPoint(x: 340, y: 225),
    endRadius: 245,
    options: [.drawsAfterEndLocation]
)
context.restoreGState()

// Soft landing zones make the two real Finder icons feel intentional without
// drawing fake icon tiles into the artwork.
for x in [170.0, 510.0] {
    let halo = NSRect(x: x - 73, y: 166, width: 146, height: 146)
    NSColor.white.withAlphaComponent(0.025).setFill()
    NSBezierPath(ovalIn: halo).fill()
}

// Finder chooses black icon-label text on custom image backgrounds and does
// not expose a supported text-color control. These small warm plates provide
// reliable contrast while keeping the rest of the canvas dark.
drawLabelPlate(x: 105, width: 130)
drawLabelPlate(x: 445, width: 130)

drawCentered(
    "Drag Battery Hog to Applications",
    y: 56,
    font: NSFont.systemFont(ofSize: 27, weight: .semibold),
    color: NSColor(hex: 0xf5f8ef),
    tracking: -0.45
)
drawCentered(
    "Then launch it from Spotlight or Launchpad.",
    y: 94,
    font: NSFont.systemFont(ofSize: 13, weight: .regular),
    color: NSColor(hex: 0xf5f8ef, alpha: 0.58)
)

drawPulseArrow(y: 236)

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    fatalError("Could not encode the installer background")
}

let outputURL = URL(fileURLWithPath: outputPath)
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try png.write(to: outputURL, options: .atomic)
print("wrote \(outputURL.path)")
