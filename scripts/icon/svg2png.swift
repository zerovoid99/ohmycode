// Renders an SVG to a PNG of the given width, keeping transparency (AppKit reads SVG).
//   swift scripts/icon/svg2png.swift in.svg out.png 512
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 4, let image = NSImage(contentsOf: URL(fileURLWithPath: arguments[1])), let pixels = Int(arguments[3]) else {
    FileHandle.standardError.write("usage: svg2png in.svg out.png pixels\n".data(using: .utf8)!)
    exit(1)
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: pixels, height: pixels)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[2]))
