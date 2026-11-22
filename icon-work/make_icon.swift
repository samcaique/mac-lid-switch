import AppKit
import Foundation

let outputDirectory = CommandLine.arguments[1]
let liveIconDirectory = CommandLine.arguments[2]
enum LightFinish { case lit, dark, neutral }

func renderIcon(size: Int, finish: LightFinish, file: String) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = graphics
    let c = graphics.cgContext
    c.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    c.setAllowsAntialiasing(true)
    c.setShouldAntialias(true)
    let rect = NSRect(x: 72, y: 72, width: 880, height: 880)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 194, yRadius: 194)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
    shape.fill()
    c.restoreGState()
    NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.16, alpha: 1), NSColor(calibratedRed: 0.26, green: 0.29, blue: 0.33, alpha: 1)])!.draw(in: shape, angle: 90)
    c.saveGState()
    shape.addClip()
    let glowColors = [NSColor(calibratedRed: 0.62, green: 0.72, blue: 0.86, alpha: 0.27).cgColor, NSColor(calibratedRed: 0.28, green: 0.38, blue: 0.54, alpha: 0).cgColor] as CFArray
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glowColors, locations: [0, 1])!
    if finish == .lit { c.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 565), startRadius: 30, endCenter: CGPoint(x: 512, y: 565), endRadius: 420, options: []) }
    c.restoreGState()
    NSColor.white.withAlphaComponent(0.22).setStroke()
    shape.lineWidth = 2.3
    shape.stroke()
    let inner = NSBezierPath(roundedRect: rect.insetBy(dx: 8, dy: 8), xRadius: 187, yRadius: 187)
    NSColor.black.withAlphaComponent(0.12).setStroke()
    inner.lineWidth = 1.2
    inner.stroke()

    let lid = NSBezierPath(roundedRect: NSRect(x: 220, y: 348, width: 584, height: 372), xRadius: 46, yRadius: 46)
    NSColor(calibratedWhite: 0.79, alpha: 1).setStroke()
    lid.lineWidth = 19
    lid.stroke()
    NSColor(calibratedWhite: 0.65, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 197, y: 294, width: 630, height: 20), xRadius: 10, yRadius: 10).fill()
    let light = NSBezierPath(ovalIn: NSRect(x: 450, y: 473, width: 124, height: 124))
    c.saveGState()
    switch finish {
    case .lit:
        c.setShadow(offset: .zero, blur: 48, color: NSColor.white.cgColor)
        NSColor.white.setFill()
    case .dark: NSColor(calibratedWhite: 0.045, alpha: 1).setFill()
    case .neutral: NSColor(calibratedWhite: 0.5, alpha: 1).setFill()
    }
    light.fill()
    c.restoreGState()
    NSColor(calibratedWhite: 0.65, alpha: 1).setStroke()
    light.lineWidth = 7
    light.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: file))
}

for base in [16, 32, 128, 256, 512] {
    try renderIcon(size: base, finish: .neutral, file: "\(outputDirectory)/icon_\(base)x\(base).png")
    try renderIcon(size: base * 2, finish: .neutral, file: "\(outputDirectory)/icon_\(base)x\(base)@2x.png")
}

try renderIcon(size: 512, finish: .lit, file: liveIconDirectory + "/DockOn.png")
try renderIcon(size: 512, finish: .dark, file: liveIconDirectory + "/DockOff.png")
