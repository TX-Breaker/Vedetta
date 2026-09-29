// Renders the Vedetta app icon (1024x1024 PNG). Usage: swift make-icon.swift out.png
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}

// Squircle body (Big Sur / Tahoe grid: 824pt body, 100pt margin).
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 186
let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Soft drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.35))
ctx.addPath(shape)
ctx.setFillColor(color(0.02, 0.08, 0.16))
ctx.fillPath()
ctx.restoreGState()

// Background gradient
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [color(0.03, 0.10, 0.22), color(0.02, 0.32, 0.50), color(0.10, 0.70, 0.84)] as CFArray,
                    locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 150, y: 120), end: CGPoint(x: 880, y: 930), options: [])

// Subtle radial glow behind the lens
let glow = CGGradient(colorsSpace: cs, colors: [color(0.45, 0.95, 1.0, 0.45), color(0.45, 0.95, 1.0, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 520), startRadius: 0, endCenter: CGPoint(x: 512, y: 520), endRadius: 430, options: [])

let c = CGPoint(x: 512, y: 512)

// Outer glass ring
func ring(_ r: CGFloat, width: CGFloat, colors: [CGColor]) {
    ctx.saveGState()
    let p = CGMutablePath()
    p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    p.addEllipse(in: CGRect(x: c.x - r + width, y: c.y - r + width, width: 2 * (r - width), height: 2 * (r - width)))
    ctx.addPath(p)
    ctx.clip(using: .evenOdd)
    let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: CGPoint(x: c.x - r, y: c.y + r), end: CGPoint(x: c.x + r, y: c.y - r), options: [])
    ctx.restoreGState()
}

// Lens housing
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0, 0, 0, 0.45))
ctx.addEllipse(in: CGRect(x: c.x - 300, y: c.y - 300, width: 600, height: 600))
ctx.setFillColor(color(0.03, 0.06, 0.12))
ctx.fillPath()
ctx.restoreGState()
ring(300, width: 44, colors: [color(0.95, 0.99, 1.0, 0.95), color(0.55, 0.80, 0.92, 0.85), color(0.20, 0.45, 0.60, 0.9)])

// Iris
let irisR: CGFloat = 212
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: c.x - irisR, y: c.y - irisR, width: 2 * irisR, height: 2 * irisR))
ctx.clip()
let iris = CGGradient(colorsSpace: cs, colors: [color(0.20, 0.85, 1.0), color(0.04, 0.42, 0.72), color(0.02, 0.12, 0.28)] as CFArray,
                      locations: [0, 0.55, 1])!
ctx.drawRadialGradient(iris, startCenter: CGPoint(x: c.x - 40, y: c.y + 50), startRadius: 10, endCenter: c, endRadius: irisR, options: [.drawsAfterEndLocation])
// Iris fibres
ctx.setStrokeColor(color(0.6, 0.95, 1.0, 0.18))
ctx.setLineWidth(5)
for i in 0..<36 {
    let a = CGFloat(i) / 36 * 2 * .pi
    ctx.move(to: CGPoint(x: c.x + cos(a) * 100, y: c.y + sin(a) * 100))
    ctx.addLine(to: CGPoint(x: c.x + cos(a) * 205, y: c.y + sin(a) * 205))
}
ctx.strokePath()
ctx.restoreGState()

// Pupil
ctx.addEllipse(in: CGRect(x: c.x - 92, y: c.y - 92, width: 184, height: 184))
ctx.setFillColor(color(0.01, 0.03, 0.07))
ctx.fillPath()

// Specular highlights (liquid glass)
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: c.x - 150, y: c.y + 40, width: 150, height: 110))
ctx.setFillColor(color(1, 1, 1, 0.85))
ctx.fillPath()
ctx.addEllipse(in: CGRect(x: c.x + 60, y: c.y - 110, width: 56, height: 44))
ctx.setFillColor(color(1, 1, 1, 0.45))
ctx.fillPath()
ctx.restoreGState()

// Top glass sheen over the whole body
let sheen = CGGradient(colorsSpace: cs, colors: [color(1, 1, 1, 0.28), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])

// Recording indicator
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 24, color: color(1, 0.25, 0.25, 0.9))
ctx.addEllipse(in: CGRect(x: 742, y: 742, width: 74, height: 74))
ctx.setFillColor(color(1, 0.27, 0.27))
ctx.fillPath()
ctx.restoreGState()
ctx.restoreGState()

// Inner border
ctx.addPath(shape)
ctx.setStrokeColor(color(1, 1, 1, 0.22))
ctx.setLineWidth(3)
ctx.strokePath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("icon written: \(out)")
