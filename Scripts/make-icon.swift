// Draws the Beady Eye app icon and writes Resources/AppIcon.icns.
// Run: swift Scripts/make-icon.swift   (needs iconutil, which ships with macOS)
import AppKit

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let u = s / 1024   // design units

    // macOS icon body: 824pt square centred in the 1024 canvas, with a soft shadow.
    let body = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185 * u, cornerHeight: 185 * u, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 24 * u, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(bodyPath); ctx.setFillColor(NSColor(red: 0.12, green: 0.14, blue: 0.35, alpha: 1).cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let bg = CGGradient(colorsSpace: space, colors: [
        NSColor(red: 0.36, green: 0.34, blue: 0.95, alpha: 1).cgColor,
        NSColor(red: 0.10, green: 0.12, blue: 0.40, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512 * u, y: 924 * u), end: CGPoint(x: 512 * u, y: 100 * u), options: [])

    // Eye: an almond made of two arcs.
    let cx = 512 * u, cy = 512 * u
    let w = 560 * u, h = 330 * u
    let eye = CGMutablePath()
    eye.move(to: CGPoint(x: cx - w / 2, y: cy))
    eye.addQuadCurve(to: CGPoint(x: cx + w / 2, y: cy), control: CGPoint(x: cx, y: cy + h))
    eye.addQuadCurve(to: CGPoint(x: cx - w / 2, y: cy), control: CGPoint(x: cx, y: cy - h))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8 * u), blur: 18 * u, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(eye); ctx.setFillColor(NSColor(white: 0.97, alpha: 1).cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(eye); ctx.clip()
    // Iris: a glossy bead.
    let r = 150 * u
    let iris = CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)
    let ig = CGGradient(colorsSpace: space, colors: [
        NSColor(red: 0.45, green: 0.92, blue: 0.85, alpha: 1).cgColor,
        NSColor(red: 0.08, green: 0.55, blue: 0.75, alpha: 1).cgColor,
        NSColor(red: 0.05, green: 0.25, blue: 0.5, alpha: 1).cgColor] as CFArray, locations: [0, 0.6, 1])!
    ctx.saveGState()
    ctx.addEllipse(in: iris); ctx.clip()
    ctx.drawRadialGradient(ig, startCenter: CGPoint(x: cx - 40 * u, y: cy + 50 * u), startRadius: 0,
                           endCenter: CGPoint(x: cx, y: cy), endRadius: r, options: [.drawsAfterEndLocation])
    ctx.restoreGState()
    // Pupil
    let pr = 66 * u
    ctx.setFillColor(NSColor(red: 0.03, green: 0.05, blue: 0.14, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: cx - pr, y: cy - pr, width: 2 * pr, height: 2 * pr))
    // Highlights
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.95).cgColor)
    ctx.fillEllipse(in: CGRect(x: cx - 88 * u, y: cy + 38 * u, width: 58 * u, height: 58 * u))
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.6).cgColor)
    ctx.fillEllipse(in: CGRect(x: cx + 40 * u, y: cy - 78 * u, width: 26 * u, height: 26 * u))
    ctx.restoreGState()

    // Lid outline
    ctx.addPath(eye); ctx.setStrokeColor(NSColor(red: 0.1, green: 0.12, blue: 0.35, alpha: 0.55).cgColor)
    ctx.setLineWidth(10 * u); ctx.strokePath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let set = root.appendingPathComponent("build/AppIcon.iconset")
try? fm.removeItem(at: set)
try! fm.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(size: base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(size: base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! fm.createDirectory(at: root.appendingPathComponent("Resources"), withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
try? fm.removeItem(at: set)
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
