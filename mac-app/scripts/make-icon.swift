// Renders the app icon to a 1024px PNG: swift scripts/make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: 824px rounded square centred on a 1024 canvas.
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSGradient(colors: [NSColor(srgbRed: 0.98, green: 0.36, blue: 0.45, alpha: 1),
                    NSColor(srgbRed: 0.55, green: 0.27, blue: 0.93, alpha: 1)])!
    .draw(in: shape, angle: -60)
NSGraphicsContext.current?.restoreGraphicsState()

// Soft speech arcs beside the lips.
NSColor.white.withAlphaComponent(0.18).setStroke()
for (i, r) in [CGFloat(250), 320, 390].enumerated() {
    let arc = NSBezierPath()
    arc.appendArc(withCenter: NSPoint(x: size / 2, y: size / 2 - 10), radius: r, startAngle: -32, endAngle: 32)
    arc.lineWidth = 26 - CGFloat(i) * 5
    arc.lineCapStyle = .round
    arc.stroke()
}

let config = NSImage.SymbolConfiguration(pointSize: 420, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "mouth.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = symbol.size
    symbol.draw(in: NSRect(x: (size - s.width) / 2 - 40, y: (size - s.height) / 2 - 10, width: s.width, height: s.height))
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
