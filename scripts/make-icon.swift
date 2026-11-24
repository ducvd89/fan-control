// Renders the app icon: a fan over a cool→hot gradient with a temperature curve.
// Usage: swift scripts/make-icon.swift <output-dir>   (writes AppIcon.iconset + AppIcon.icns)
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources")
let iconset = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(size s: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(s), pixelsHigh: Int(s), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // macOS icon grid: 824pt rounded square centred in 1024, with a soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(tilePath); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(srgbRed: 0.07, green: 0.11, blue: 0.22, alpha: 1).cgColor,
        NSColor(srgbRed: 0.11, green: 0.20, blue: 0.38, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])

    // Glow ring: cool cyan at the bottom-left warming to orange at the top-right.
    let center = CGPoint(x: 512, y: 560)
    let ringColors = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(srgbRed: 0.20, green: 0.85, blue: 1.00, alpha: 1).cgColor,
        NSColor(srgbRed: 1.00, green: 0.80, blue: 0.25, alpha: 1).cgColor,
        NSColor(srgbRed: 1.00, green: 0.35, blue: 0.20, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: center.x - 290, y: center.y - 290, width: 580, height: 580))
    ctx.addEllipse(in: CGRect(x: center.x - 260, y: center.y - 260, width: 520, height: 520))
    ctx.clip(using: .evenOdd)
    ctx.drawLinearGradient(ringColors, start: CGPoint(x: 200, y: 200), end: CGPoint(x: 824, y: 824), options: [])
    ctx.restoreGState()

    // Fan blades: five swept blades, each a curved teardrop, rotated around the hub.
    // Scimitar-shaped blade pointing up from the hub, swept clockwise.
    let blade = CGMutablePath()
    blade.move(to: CGPoint(x: -30, y: 50))
    blade.addCurve(to: CGPoint(x: 120, y: 225), control1: CGPoint(x: -60, y: 140), control2: CGPoint(x: 10, y: 225))
    blade.addCurve(to: CGPoint(x: 75, y: 40), control1: CGPoint(x: 190, y: 220), control2: CGPoint(x: 150, y: 100))
    blade.addCurve(to: CGPoint(x: -30, y: 50), control1: CGPoint(x: 40, y: 20), control2: CGPoint(x: 0, y: 25))
    blade.closeSubpath()

    let bladeFill = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(white: 1, alpha: 1).cgColor,
        NSColor(srgbRed: 0.78, green: 0.88, blue: 1, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    for i in 0..<7 {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: CGFloat(i) * 2 * .pi / 7)
        ctx.scaleBy(x: 0.86, y: 0.86)
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.addPath(blade); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(blade); ctx.clip()
        ctx.drawLinearGradient(bladeFill, start: CGPoint(x: 0, y: 40), end: CGPoint(x: 120, y: 225), options: [])
        ctx.restoreGState()
    }

    // Hub.
    ctx.setFillColor(NSColor(srgbRed: 0.11, green: 0.20, blue: 0.38, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: center.x - 62, y: center.y - 62, width: 124, height: 124))
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillEllipse(in: CGRect(x: center.x - 38, y: center.y - 38, width: 76, height: 76))

    // Fan curve along the bottom, echoing the profile editor.
    let curve = CGMutablePath()
    curve.move(to: CGPoint(x: 210, y: 180))
    curve.addCurve(to: CGPoint(x: 814, y: 250), control1: CGPoint(x: 470, y: 175), control2: CGPoint(x: 640, y: 185))
    ctx.saveGState()
    ctx.setLineWidth(16); ctx.setLineCap(.round)
    ctx.addPath(curve); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(ringColors, start: CGPoint(x: 210, y: 0), end: CGPoint(x: 814, y: 0), options: [])
    ctx.restoreGState()
    for p in [CGPoint(x: 210, y: 180), CGPoint(x: 520, y: 190), CGPoint(x: 814, y: 250)] {
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x - 17, y: p.y - 17, width: 34, height: 34))
    }
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try draw(size: px).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
try p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("Wrote \(out.appendingPathComponent("AppIcon.icns").path)")
