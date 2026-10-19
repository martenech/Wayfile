// Renders logo.png onto a macOS app-icon tile and writes a 1024×1024 master PNG.
// macOS 26 boxes non-squircle icons into a grey tile, so the logo gets its own tile here.
// Usage: swift scripts/make-icon.swift <logo.png> <out.png> [x,y,size]
// With x,y,size (pixels, from the top left) the logo is artwork that already has its own tile:
// that square is cropped out and fills the whole icon tile instead of sitting on the light background.
import AppKit

let args = CommandLine.arguments
guard args.count == 3 || args.count == 4, let logo = NSImage(contentsOfFile: args[1]) else {
    fputs("usage: make-icon.swift <logo.png> <out.png> [x,y,size]\n", stderr)
    exit(1)
}
let bleedCrop: CGRect? = args.count == 4 ? {
    let v = args[3].split(separator: ",").compactMap { Double($0) }
    guard v.count == 3 else { fputs("crop must be x,y,size\n", stderr); exit(1) }
    return CGRect(x: v[0], y: v[1], width: v[2], height: v[2])
}() : nil

let canvas: CGFloat = 1024
// Apple's macOS icon grid: an 824 pt tile centred on a 1024 canvas, ~185 pt corner radius.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 185

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high

let path = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

// Soft drop shadow under the tile, like system icons.
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor.white.setFill()
path.fill()
NSGraphicsContext.restoreGraphicsState()

// Light, slightly blue gradient so the blue folder stands out.
NSGradient(colors: [NSColor(srgbRed: 0.98, green: 0.99, blue: 1.0, alpha: 1),
                    NSColor(srgbRed: 0.86, green: 0.92, blue: 0.99, alpha: 1)])!
    .draw(in: path, angle: -90)

// Hairline edge for definition on light backgrounds.
NSColor.black.withAlphaComponent(0.08).setStroke()
path.lineWidth = 2
path.stroke()

path.addClip()
if let crop = bleedCrop, let cg = logo.cgImage(forProposedRect: nil, context: nil, hints: nil)?.cropping(to: crop) {
    // Full-bleed artwork, clipped to the tile.
    NSImage(cgImage: cg, size: crop.size).draw(in: tile, from: .zero, operation: .sourceOver, fraction: 1)
} else {
    // Logo fills most of the tile, centred.
    let inset: CGFloat = 40
    logo.draw(in: tile.insetBy(dx: inset, dy: inset), from: .zero, operation: .sourceOver, fraction: 1)
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
