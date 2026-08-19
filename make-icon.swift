// Renders AppIcon.icns for Server Gauge: a macOS-style squircle with a
// teal→deep-sea gradient and the server.rack glyph. Run when the design
// changes; the generated .icns is committed and copied by build.sh.
//
//   swift make-icon.swift
//
import AppKit

let px = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Apple's icon grid: the squircle fills ~824 of 1024 points.
let size = CGFloat(px)
let inset: CGFloat = 100
let squircle = NSBezierPath(
    roundedRect: NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset),
    xRadius: 185, yRadius: 185
)
NSGradient(
    starting: NSColor(calibratedRed: 0.13, green: 0.72, blue: 0.69, alpha: 1),
    ending: NSColor(calibratedRed: 0.03, green: 0.22, blue: 0.33, alpha: 1)
)!.draw(in: squircle, angle: -90)

// server.rack, tinted white, centered.
let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .medium)
if let sym = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = sym.size
    let tinted = NSImage(size: s)
    tinted.lockFocus()
    sym.draw(in: NSRect(origin: .zero, size: s))
    NSColor.white.set()
    NSRect(origin: .zero, size: s).fill(using: .sourceAtop)
    tinted.unlockFocus()
    let scale = min(520 / s.width, 520 / s.height)
    let w = s.width * scale, h = s.height * scale
    tinted.draw(
        in: NSRect(x: (size - w) / 2, y: (size - h) / 2, width: w, height: h),
        from: .zero, operation: .sourceOver, fraction: 1
    )
}

NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = base.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try! png.write(to: iconset.appendingPathComponent("icon_512x512@2x.png"))

// Downscale the master for the remaining slots.
for (name, pts) in [
    ("icon_512x512", 512), ("icon_256x256@2x", 512), ("icon_256x256", 256),
    ("icon_128x128@2x", 256), ("icon_128x128", 128), ("icon_32x32@2x", 64),
    ("icon_32x32", 32), ("icon_16x16@2x", 32), ("icon_16x16", 16),
] {
    let sips = Process()
    sips.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    sips.arguments = [
        "-z", String(pts), String(pts),
        iconset.appendingPathComponent("icon_512x512@2x.png").path,
        "--out", iconset.appendingPathComponent("\(name).png").path,
    ]
    sips.standardOutput = Pipe()
    try! sips.run()
    sips.waitUntilExit()
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", base.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "Wrote AppIcon.icns" : "iconutil failed")
