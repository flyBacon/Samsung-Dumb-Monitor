// SPDX-License-Identifier: MPL-2.0
// swift Tools/GenerateIcon.swift <output.iconset>
// iconutil -c icns <output.iconset> -o Resources/AppIcon.icns
import AppKit

guard CommandLine.arguments.count == 2 else {
    fatalError("Supply an output .iconset directory.")
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func spiralEye(center: NSPoint) {
    let path = NSBezierPath()
    for index in 0...160 {
        let progress = CGFloat(index) / 160
        let angle = progress * .pi * 3.5
        let radius = 4 + progress * 44
        let point = NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        if index == 0 { path.move(to: point) } else { path.line(to: point) }
    }
    path.lineWidth = 12
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.stroke()
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        NSColor(srgbRed: 0.93, green: 0.94, blue: 0.91, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904), xRadius: 200, yRadius: 200).fill()
        NSColor(srgbRed: 0.19, green: 0.24, blue: 0.25, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 206, y: 327, width: 612, height: 446), xRadius: 72, yRadius: 72).fill()
        NSBezierPath(roundedRect: NSRect(x: 461, y: 231, width: 102, height: 126), xRadius: 20, yRadius: 20).fill()
        NSBezierPath(roundedRect: NSRect(x: 358, y: 218, width: 308, height: 46), xRadius: 23, yRadius: 23).fill()
        NSColor(srgbRed: 0.92, green: 0.96, blue: 0.90, alpha: 1).setStroke()
        spiralEye(center: NSPoint(x: 384, y: 580))
        spiralEye(center: NSPoint(x: 638, y: 568))
        let mouth = NSBezierPath()
        mouth.move(to: NSPoint(x: 465, y: 437)); mouth.line(to: NSPoint(x: 557, y: 447))
        mouth.lineWidth = 25
        mouth.lineCapStyle = .round
        mouth.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
