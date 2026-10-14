import AppKit

// Reproducible vector artwork: a document and a speech waveform.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: xcrun swift scripts/make-icon.swift <appiconset-directory>\n", stderr)
    exit(1)
}
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let sizes = [16, 32, 128, 256, 512]
var entries: [[String: String]] = []
for size in sizes {
    for scale in [1, 2] {
        let pixels = size * scale
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let tile = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 200, yRadius: 200)
        NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.29, blue: 0.9, alpha: 1), ending: NSColor(calibratedRed: 0.32, green: 0.53, blue: 1, alpha: 1))!.draw(in: tile, angle: 70)
        NSColor.white.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: NSRect(x: 244, y: 220, width: 536, height: 584), xRadius: 55, yRadius: 55).fill()
        NSColor.white.setFill()
        for (index, height) in [110, 220, 350, 260, 150].enumerated() {
            NSBezierPath(roundedRect: NSRect(x: 307 + index * 83, y: 512 - height / 2, width: 42, height: height), xRadius: 21, yRadius: 21).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
        entries.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": entries, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("Contents.json"))
