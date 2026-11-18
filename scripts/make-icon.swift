// Draws the app icon into an .iconset (./build.sh --icon).
//
// Same layout as the WatchDiary logo: a tile in the main color at 18 % opacity on white (so it
// looks the same in light and dark Docks), a square in the full main color, and the glyph in
// white: two round-stroked arrows, up (upload) and down (download). Drawn in the logo's
// coordinates (viewBox 512, y down); the tile (8…504) sits on Apple's icon grid
// (824 × 824 with a 100 px margin at 1024).
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// FileHub's main color: petrol.
let mainColor: UInt32 = 0x0F8FA8
let barWidth: CGFloat = 26

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let s = CGFloat(pixels) / 1024
    let k = 824 / 496 * s
    let transform = NSAffineTransform()
    transform.translateX(by: 100 * s - 8 * k, yBy: CGFloat(pixels) - 100 * s + 8 * k)
    transform.scaleX(by: k, yBy: -k)
    transform.concat()

    // Tile: white with a shadow, the main color at 18 % opacity on top.
    let tile = NSBezierPath(roundedRect: NSRect(x: 8, y: 8, width: 496, height: 496), xRadius: 112, yRadius: 112)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 16 * s
    shadow.shadowOffset = NSSize(width: 0, height: -6 * s)
    shadow.set()
    NSColor.white.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    color(mainColor, 0.18).setFill()
    tile.fill()

    // Square in the full main color, as in the logo: 86…426 with radius 68.
    color(mainColor).setFill()
    NSBezierPath(roundedRect: NSRect(x: 86, y: 86, width: 340, height: 340), xRadius: 68, yRadius: 68).fill()

    // The glyph keeps its coordinates (area 96…388 × 124…416, center 242/270) and is scaled with
    // its stroke width onto the square 86…426 (center 256/256).
    let symbolScale: CGFloat = 340 / 292
    let place = NSAffineTransform()
    place.translateX(by: 256, yBy: 256)
    place.scale(by: symbolScale)
    place.translateX(by: -242, yBy: -270)
    place.concat()

    // Left ↑ (upload), right ↓ (download).
    let symbol = NSBezierPath()
    symbol.lineWidth = barWidth
    symbol.lineCapStyle = .round
    symbol.lineJoinStyle = .round
    symbol.move(to: NSPoint(x: 200, y: 346))
    symbol.line(to: NSPoint(x: 200, y: 194))
    symbol.move(to: NSPoint(x: 162, y: 232))
    symbol.line(to: NSPoint(x: 200, y: 194))
    symbol.line(to: NSPoint(x: 238, y: 232))
    symbol.move(to: NSPoint(x: 284, y: 194))
    symbol.line(to: NSPoint(x: 284, y: 346))
    symbol.move(to: NSPoint(x: 246, y: 308))
    symbol.line(to: NSPoint(x: 284, y: 346))
    symbol.line(to: NSPoint(x: 322, y: 308))
    NSColor.white.setStroke()
    symbol.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for entry in sizes {
    try render(pixels: entry.pixels).write(to: output.appendingPathComponent("\(entry.name).png"))
}
print("Icon-Set geschrieben: \(output.path)")
