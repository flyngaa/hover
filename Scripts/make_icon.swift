import AppKit
import Foundation

// Loads Resources/Logo.png, emits every size macOS needs, and packs them into
// Resources/AppIcon.icns.

let sourcePath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/Logo.png"
guard let sourceImage = NSImage(contentsOfFile: sourcePath) else {
    fatalError("Could not load \(sourcePath)")
}

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

func render(px: Int) -> Data {
    let size = CGFloat(px)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    NSGraphicsContext.current?.imageInterpolation = .high

    // Dark rounded tile behind the logo, matching the app's dark UI background
    // (#1E1E1E). The logo PNG is a white mark on transparent, so it composites
    // cleanly on top. 22.37% corner radius approximates the macOS icon squircle.
    let bounds = NSRect(x: 0, y: 0, width: size, height: size)
    let radius = size * 0.2237
    NSColor(srgbRed: 30 / 255.0, green: 30 / 255.0, blue: 30 / 255.0, alpha: 1).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

    // .sourceOver (not .copy) so the logo blends onto the tile instead of
    // overwriting it — including the transparent areas.
    sourceImage.draw(
        in: bounds,
        from: .zero,
        operation: .sourceOver,
        fraction: 1.0
    )

    image.unlockFocus()

    guard
        let tiff = image.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
    else {
        fatalError("Failed to render \(px)px icon")
    }
    return png
}

let fm = FileManager.default
let iconset = "AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

for entry in sizes {
    let data = render(px: entry.px)
    let url = URL(fileURLWithPath: "\(iconset)/\(entry.name).png")
    try! data.write(to: url)
}

let icnsPath = "Resources/AppIcon.icns"
try? fm.removeItem(atPath: icnsPath)

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset, "-o", icnsPath]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(task.terminationStatus)")
}

try? fm.removeItem(atPath: iconset)
print("Wrote \(icnsPath)")
