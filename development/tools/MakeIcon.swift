import AppKit
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let n = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let inset = Double(n) * 0.05
        NSColor(srgbRed: 0.99, green: 0.97, blue: 0.93, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: Double(n) - 2 * inset, height: Double(n) - 2 * inset), xRadius: Double(n) * 0.2, yRadius: Double(n) * 0.2).fill()
        let color = NSColor(srgbRed: 0.74, green: 0.39, blue: 0.13, alpha: 1)
        let config = NSImage.SymbolConfiguration(pointSize: Double(n) * 0.57, weight: .regular).applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let symbol = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
        let ratio = min(Double(n) * 0.63 / symbol.size.width, Double(n) * 0.63 / symbol.size.height)
        let size = NSSize(width: symbol.size.width * ratio, height: symbol.size.height * ratio)
        symbol.draw(in: NSRect(x: (Double(n) - size.width) / 2, y: (Double(n) - size.height) / 2, width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(base)x\(base)" + (scale == 2 ? "@2x" : "") + ".png"
        try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
}
