// Draws the DMG window background (light, so Finder's black icon labels stay readable; Studio's orange arrow
// from the app to Applications) at 1x and 2x.
// Usage: swift scripts/dmg-background.swift <out-dir>   → background.png, background@2x.png
import AppKit

let W: CGFloat = 640, H: CGFloat = 400
// icon centers, in Finder's top-left coordinates (keep in sync with scripts/dmg-settings.py)
let app = CGPoint(x: 170, y: 205), apps = CGPoint(x: 470, y: 205)

func hex(_ s: String, _ a: CGFloat = 1) -> NSColor {
    var v: UInt64 = 0; Scanner(string: s).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: a)
}

func render(scale: CGFloat, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // flip to top-left coordinates, like Finder
    ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)

    // background: vertical gradient plus a soft warm glow behind the arrow
    NSGradient(colors: [hex("fbfaf8"), hex("f1eee9")])!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)
    let glow = NSGradient(colors: [hex("ee8a5c", 0.14), hex("ee8a5c", 0)])!
    glow.draw(fromCenter: CGPoint(x: W / 2, y: app.y), radius: 0, toCenter: CGPoint(x: W / 2, y: app.y), radius: 260, options: [])

    // subtle grid, like the website
    ctx.setStrokeColor(hex("1d1f26", 0.045).cgColor); ctx.setLineWidth(1)
    var x: CGFloat = 0
    while x <= W { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: H)); x += 32 }
    var y: CGFloat = 0
    while y <= H { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: W, y: y)); y += 32 }
    ctx.strokePath()

    // title + hint (drawn unflipped)
    func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, top: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        let a = NSAttributedString(string: s, attributes: attrs)
        let sz = a.size()
        ctx.saveGState(); ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)
        a.draw(at: CGPoint(x: (W - sz.width) / 2, y: H - top - sz.height))
        ctx.restoreGState()
    }
    text("Install Studio", size: 22, weight: .semibold, color: hex("1d1f26"), top: 42)
    text("Drag Studio into your Applications folder", size: 13, weight: .regular, color: hex("1d1f26", 0.55), top: 76)

    // arrow between the icons: a gentle arc, dashed, with a solid head
    let from = CGPoint(x: app.x + 84, y: app.y), to = CGPoint(x: apps.x - 84, y: app.y)
    let ctrl = CGPoint(x: W / 2, y: app.y - 34)
    let arrow = CGMutablePath(); arrow.move(to: from); arrow.addQuadCurve(to: to, control: ctrl)
    ctx.addPath(arrow)
    ctx.setStrokeColor(hex("e2773f").cgColor); ctx.setLineWidth(3); ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [1, 9]); ctx.strokePath(); ctx.setLineDash(phase: 0, lengths: [])
    // head, pointing along the curve's end tangent
    let ang = atan2(to.y - ctrl.y, to.x - ctrl.x)
    let head = CGMutablePath()
    head.move(to: CGPoint(x: to.x + 4 * cos(ang), y: to.y + 4 * sin(ang)))
    head.addLine(to: CGPoint(x: to.x - 13 * cos(ang - 0.5), y: to.y - 13 * sin(ang - 0.5)))
    head.addLine(to: CGPoint(x: to.x - 13 * cos(ang + 0.5), y: to.y - 13 * sin(ang + 0.5)))
    head.closeSubpath()
    ctx.addPath(head); ctx.setFillColor(hex("e2773f").cgColor); ctx.fillPath()

    // (nothing near the bottom: Finder's tab bar, when the user shows it, covers the last ~40pt)

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
render(scale: 1, to: out + "/background.png")
render(scale: 2, to: out + "/background@2x.png")
print("wrote \(out)/background.png, background@2x.png")
