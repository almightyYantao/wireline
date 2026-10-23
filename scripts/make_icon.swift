// Renders the Wireline app icon: a dark terminal card — capsule tab track,
// gradient prompt chevron and cursor — over a second card tilted behind it
// (a split), on a frosted light squircle with violet / teal glows.
// Run with:  swift scripts/make_icon.swift [out.png]
import AppKit

let variant = "C"
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icon_1024.png"
let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let cs = CGColorSpaceCreateDeviceRGB()
func c(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((h>>16)&255)/255, green: CGFloat((h>>8)&255)/255, blue: CGFloat(h&255)/255, alpha: a)
}
func rr(_ r: CGRect, _ rad: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil) }
let m: CGFloat = 100
let tile = CGRect(x: m, y: m, width: S-2*m, height: S-2*m)
let tilePath = rr(tile, tile.width*0.225)

// drop shadow of the tile (macOS icon grid style)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: c(0x000000, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(c(0x101320)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState(); ctx.addPath(tilePath); ctx.clip()
switch variant {
case "B":
    let g = CGGradient(colorsSpace: cs, colors: [c(0x5B5BF0), c(0x3A7BEA), c(0x22C3C9)] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: m, y: S-m), end: CGPoint(x: S-m, y: m), options: [])
case "C":
    let g = CGGradient(colorsSpace: cs, colors: [c(0xF4F6FB), c(0xDDE3F2)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: S-m), end: CGPoint(x: 0, y: m), options: [])
    let r = CGGradient(colorsSpace: cs, colors: [c(0x8E7CFF, 0.35), c(0x8E7CFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(r, startCenter: CGPoint(x: 300, y: 820), startRadius: 0, endCenter: CGPoint(x: 300, y: 820), endRadius: 520, options: [])
    let r2 = CGGradient(colorsSpace: cs, colors: [c(0x29D3C9, 0.30), c(0x29D3C9, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(r2, startCenter: CGPoint(x: 820, y: 220), startRadius: 0, endCenter: CGPoint(x: 820, y: 220), endRadius: 480, options: [])
default:
    let g = CGGradient(colorsSpace: cs, colors: [c(0x1C2140), c(0x0B0E1A)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: S-m), end: CGPoint(x: 0, y: m), options: [])
    let r = CGGradient(colorsSpace: cs, colors: [c(0x6E63FF, 0.45), c(0x6E63FF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(r, startCenter: CGPoint(x: 280, y: 860), startRadius: 0, endCenter: CGPoint(x: 280, y: 860), endRadius: 560, options: [])
    let r2 = CGGradient(colorsSpace: cs, colors: [c(0x1FC8D6, 0.35), c(0x1FC8D6, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(r2, startCenter: CGPoint(x: 860, y: 200), startRadius: 0, endCenter: CGPoint(x: 860, y: 200), endRadius: 520, options: [])
}
ctx.restoreGState()
// rim
ctx.addPath(tilePath); ctx.setStrokeColor(c(0xFFFFFF, variant == "C" ? 0.9 : 0.10)); ctx.setLineWidth(4); ctx.strokePath()

let dark = variant == "C"
let cardFill = dark ? c(0x161A2B) : c(0xFFFFFF, 0.96)
let backFill = dark ? c(0x161A2B, 0.35) : c(0xFFFFFF, 0.28)
let ink = dark ? c(0xFFFFFF) : c(0x161A2B)
let dim = dark ? c(0xFFFFFF, 0.22) : c(0x161A2B, 0.14)

// back card (a split pane behind, slightly rotated)
ctx.saveGState()
ctx.translateBy(x: 560, y: 560); ctx.rotate(by: 0.12); ctx.translateBy(x: -560, y: -560)
ctx.addPath(rr(CGRect(x: 300, y: 330, width: 470, height: 400), 64)); ctx.setFillColor(backFill); ctx.fillPath()
ctx.restoreGState()

// front card
let card = CGRect(x: 232, y: 262, width: 520, height: 440)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: c(0x000000, dark ? 0.25 : 0.35))
ctx.addPath(rr(card, 70)); ctx.setFillColor(cardFill); ctx.fillPath()
ctx.restoreGState()

// tab capsule track in card header
let track = CGRect(x: card.minX+40, y: card.maxY-96, width: card.width-80, height: 52)
ctx.addPath(rr(track, 26)); ctx.setFillColor(dim); ctx.fillPath()
let pill = CGRect(x: track.minX+8, y: track.minY+8, width: 190, height: 36)
ctx.addPath(rr(pill, 18))
let pillG = CGGradient(colorsSpace: cs, colors: [c(0x6E63FF), c(0x1FC8D6)] as CFArray, locations: [0,1])!
ctx.saveGState(); ctx.clip()
ctx.drawLinearGradient(pillG, start: CGPoint(x: pill.minX, y: 0), end: CGPoint(x: pill.maxX, y: 0), options: [])
ctx.restoreGState()

// prompt chevron + cursor
let chev = CGMutablePath()
chev.move(to: CGPoint(x: 312, y: 512)); chev.addLine(to: CGPoint(x: 392, y: 448)); chev.addLine(to: CGPoint(x: 312, y: 384))
ctx.saveGState()
ctx.addPath(chev); ctx.setLineWidth(46); ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.replacePathWithStrokedPath(); ctx.clip()
let g2 = CGGradient(colorsSpace: cs, colors: [c(0x6E63FF), c(0x1FC8D6)] as CFArray, locations: [0,1])!
ctx.drawLinearGradient(g2, start: CGPoint(x: 300, y: 520), end: CGPoint(x: 400, y: 380), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()
ctx.addPath(rr(CGRect(x: 440, y: 358, width: 150, height: 40), 20)); ctx.setFillColor(ink); ctx.fillPath()

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try? FileManager.default.createDirectory(atPath: (out as NSString).deletingLastPathComponent,
                                         withIntermediateDirectories: true)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
