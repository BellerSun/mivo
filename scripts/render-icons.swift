import AppKit

// AppKit renders the canonical SVG directly; no separate raster geometry to maintain.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let sizes = [16, 24, 32, 48, 64, 128, 256, 512, 1024]
for name in CommandLine.arguments.dropFirst(2) {
    guard let image = NSImage(contentsOf: directory.appendingPathComponent("\(name).svg")) else {
        fatalError("Cannot load \(name).svg")
    }
    for size in sizes {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            fatalError("Cannot allocate \(size)px bitmap")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                   from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Cannot encode \(name) at \(size)px")
        }
        try png.write(to: directory.appendingPathComponent("\(name)-\(size).png"))
    }
}
