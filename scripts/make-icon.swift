// Renders the app icon (a classic player display with an LED spectrum analyzer) and writes
// Resources/AppIcon.icns. Run from the repository root: swift scripts/make-icon.swift
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(size: Int) -> CGImage {
    let s = CGFloat(size) / 1024
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: s, y: s)

    // Body: macOS icon grid (824 pt square, 100 pt margin) with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.45))
    context.addPath(bodyPath)
    context.setFillColor(color(0x1B1D36))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    let gradient = CGGradient(colorsSpace: nil, colors: [color(0x4A4F8C), color(0x1A1C35)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Title bar with grip lines, as on the classic main window.
    for i in 0..<3 {
        let y = 792 + CGFloat(i) * 22
        context.setFillColor(color(0xC9CBEA, 0.55))
        context.fill(CGRect(x: 190, y: y, width: 644, height: 8))
    }

    // Display panel.
    let panel = CGRect(x: 190, y: 220, width: 644, height: 520)
    context.addPath(CGPath(roundedRect: panel, cornerWidth: 46, cornerHeight: 46, transform: nil))
    context.setFillColor(color(0x05060C))
    context.fillPath()
    context.addPath(CGPath(roundedRect: panel.insetBy(dx: 3, dy: 3), cornerWidth: 44, cornerHeight: 44, transform: nil))
    context.setStrokeColor(color(0x8A8FD0, 0.35))
    context.setLineWidth(6)
    context.strokePath()

    // Spectrum analyzer: LED segments green → yellow → red with a peak cap per bar.
    let heights = [7, 10, 12, 9, 11, 8, 6, 9, 5]
    let segments = 13
    let barWidth: CGFloat = 52, gap: CGFloat = 14, segmentHeight: CGFloat = 26, segmentGap: CGFloat = 8
    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    let left = panel.midX - totalWidth / 2, bottom = panel.minY + 52
    for (bar, height) in heights.enumerated() {
        let x = left + CGFloat(bar) * (barWidth + gap)
        for segment in 0..<segments {
            let y = bottom + CGFloat(segment) * (segmentHeight + segmentGap)
            let level = CGFloat(segment) / CGFloat(segments - 1)
            let led: UInt32 = level > 0.75 ? 0xEF3110 : level > 0.5 ? 0xE0B020 : 0x29CE10
            let lit = segment < height
            context.setFillColor(color(led, lit ? 1 : 0.1))
            context.fill(CGRect(x: x, y: y, width: barWidth, height: segmentHeight))
        }
        let peakY = bottom + CGFloat(min(height + 1, segments - 1)) * (segmentHeight + segmentGap)
        context.setFillColor(color(0xE8E8F2))
        context.fill(CGRect(x: x, y: peakY, width: barWidth, height: 10))
    }
    context.restoreGState()
    return context.makeImage()!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let rep = NSBitmapImageRep(cgImage: render(size: points * scale))
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Resources/AppIcon.icns" : "iconutil failed")
