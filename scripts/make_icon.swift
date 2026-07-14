// Renders the Wireline app icon: a colorful, gradient-stroked "W" on a black
// squircle. Run with:  swift scripts/make_icon.swift
import AppKit

let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let S = CGFloat(size)

// ---- Black squircle background (transparent corners, as macOS icons expect).
let margin: CGFloat = 84
let bg = CGRect(x: margin, y: margin, width: S - 2*margin, height: S - 2*margin)
let radius: CGFloat = (S - 2*margin) * 0.235
let bgPath = CGPath(roundedRect: bg, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Subtle top-lit dark gradient so the black isn't flat.
ctx.saveGState()
ctx.addPath(bgPath); ctx.clip()
let bgColors = [NSColor(calibratedWhite: 0.12, alpha: 1).cgColor,
                NSColor(calibratedWhite: 0.02, alpha: 1).cgColor] as CFArray
let bgGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bgColors,
                        locations: [0, 1])!
ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
ctx.restoreGState()

// Hairline inner rim for a bit of depth.
ctx.saveGState()
ctx.addPath(bgPath)
ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.06).cgColor)
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

// ---- The "W": five points, four strokes.
let w = CGMutablePath()
let pts = [CGPoint(x: 250, y: 712),
           CGPoint(x: 366, y: 316),
           CGPoint(x: 512, y: 540),
           CGPoint(x: 658, y: 316),
           CGPoint(x: 774, y: 712)]
w.move(to: pts[0])
for p in pts.dropFirst() { w.addLine(to: p) }

// Glow under the strokes.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 34,
              color: NSColor(calibratedRed: 0.55, green: 0.4, blue: 1, alpha: 0.55).cgColor)
ctx.addPath(w)
ctx.setLineWidth(86); ctx.setLineJoin(.round); ctx.setLineCap(.round)
ctx.setStrokeColor(NSColor.white.cgColor)
ctx.strokePath()
ctx.restoreGState()

// Gradient fill clipped to the stroked W.
ctx.saveGState()
ctx.addPath(w)
ctx.setLineWidth(78); ctx.setLineJoin(.round); ctx.setLineCap(.round)
ctx.replacePathWithStrokedPath()
ctx.clip()
let colors = [
    NSColor(calibratedRed: 0.13, green: 0.83, blue: 0.93, alpha: 1).cgColor, // cyan
    NSColor(calibratedRed: 0.39, green: 0.40, blue: 0.95, alpha: 1).cgColor, // indigo
    NSColor(calibratedRed: 0.85, green: 0.28, blue: 0.94, alpha: 1).cgColor, // fuchsia
    NSColor(calibratedRed: 0.98, green: 0.57, blue: 0.24, alpha: 1).cgColor  // orange
] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                      locations: [0, 0.4, 0.72, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 250, y: 700), end: CGPoint(x: 774, y: 340),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()

image.unlockFocus()

// ---- Write PNG.
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to render icon\n".utf8)); exit(1)
}
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icon_1024.png"
try? FileManager.default.createDirectory(atPath: (out as NSString).deletingLastPathComponent,
                                         withIntermediateDirectories: true)
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
