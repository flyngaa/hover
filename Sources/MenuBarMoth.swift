import AppKit
import Observation

/// The moth Hover parks in the macOS menu bar for as long as it's running. It
/// wears the usual menu bar black/white when idle and turns red while a
/// recording is in progress, so you can tell at a glance whether Hover is
/// listening — including in Agent Mode, where there is no window or dock icon
/// to look at.
///
/// An `NSObject` because the status item reaches it through target/action.
@MainActor
final class MenuBarMoth: NSObject {

    /// Height of the moth in the menu bar, in points. The artwork is roughly
    /// twice as wide as it is tall, so pinning the *height* is what keeps it in
    /// proportion with the system's own menu bar icons; the width follows.
    private static let height = 15.0

    private var statusItem: NSStatusItem?
    private var onClick: (() -> Void)?
    private var following = false

    var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            applyMothImage()
        }
    }

    /// Keeps the moth's colour in step with `engine` for as long as the app runs.
    ///
    /// This watches the engine itself rather than going through a SwiftUI
    /// `onChange`. The moth lives outside every window, and SwiftUI stops
    /// re-evaluating a window that's hidden or covered up — which left the moth
    /// white when a recording was started by keyboard shortcut from another app.
    func follow(_ engine: TranscriberEngine) {
        guard !following else { return }
        following = true
        track(engine)
    }

    private func track(_ engine: TranscriberEngine) {
        isRecording = engine.isRecording
        withObservationTracking {
            _ = engine.isRecording
        } onChange: { [weak self] in
            // `onChange` runs just *before* the new value lands, so re-read it on
            // the next turn — and re-arm, since tracking only fires once.
            Task { @MainActor in self?.track(engine) }
        }
    }

    /// Puts the moth in the menu bar, optionally running `onClick` when it's
    /// clicked. Calling this again is a no-op: the GUI runs it once per window,
    /// and we only ever want one moth up there.
    func show(onClick: (() -> Void)? = nil) {
        guard statusItem == nil else { return }
        self.onClick = onClick

        // Variable length: the moth is wider than the square slot a status item
        // gets by default, which would otherwise clip its wings.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(clicked)
        statusItem = item
        applyMothImage()
    }

    private func applyMothImage() {
        // A template image lets macOS colour the moth itself — black on a light
        // menu bar, white on a dark one, inverted while the item is pressed.
        // The recording moth opts out of that so it can stay red.
        statusItem?.button?.image = MothArtwork.image(
            height: Self.height,
            tint: isRecording ? .systemRed : nil
        )
        statusItem?.button?.image?.isTemplate = !isRecording
        statusItem?.button?.toolTip = isRecording ? "Hover — recording" : "Hover"
    }

    @objc private func clicked() {
        onClick?()
    }
}

/// Draws the moth logo at menu bar size.
///
/// The logo is a wide moth sitting in the middle of a large square canvas, so
/// most of the file is empty space. Dropped into the menu bar as-is the moth
/// would shrink to a smudge, so we measure where the artwork actually is and
/// scale the canvas up until the moth alone fills the space we want.
private enum MothArtwork {

    /// The logo plus the tight bounds of the moth within it, expressed as a
    /// fraction of the canvas. Loaded once — measuring means rasterising, and
    /// the answer never changes while the app runs.
    private static let moth: (logo: NSImage, bounds: NSRect)? = {
        guard let url = Bundle.main.url(forResource: "Moth", withExtension: "svg"),
              let logo = NSImage(contentsOf: url),
              let bounds = artworkBounds(of: logo)
        else { return nil }
        return (logo, bounds)
    }()

    /// A moth `height` points tall, filled with `tint`, or left in the logo's
    /// own colour when `tint` is nil (for use as a template image).
    static func image(height: Double, tint: NSColor?) -> NSImage? {
        guard let (logo, bounds) = moth else { return nil }

        let aspect = (bounds.width * logo.size.width) / (bounds.height * logo.size.height)
        let size = NSSize(width: (height * aspect).rounded(), height: height)

        // A drawing handler rather than a bitmap: it's re-run at whatever scale
        // the display needs, so the moth stays crisp on Retina.
        return NSImage(size: size, flipped: false) { rect in
            logo.draw(in: canvasRect(placing: bounds, into: rect))
            if let tint {
                tint.set()
                rect.fill(using: .sourceAtop)
            }
            return true
        }
    }

    /// Where the whole canvas has to be drawn for the sub-rectangle `bounds` of
    /// it to land exactly on `target`.
    private static func canvasRect(placing bounds: NSRect, into target: NSRect) -> NSRect {
        let width = target.width / bounds.width
        let height = target.height / bounds.height
        return NSRect(
            x: target.minX - bounds.minX * width,
            y: target.minY - bounds.minY * height,
            width: width,
            height: height
        )
    }

    /// The smallest rectangle covering everything the logo actually draws, as a
    /// fraction of its canvas. Found by rasterising once and looking for the
    /// outermost pixels that aren't fully transparent.
    private static func artworkBounds(of logo: NSImage) -> NSRect? {
        let probe = 256
        let canvas = NSImage(size: NSSize(width: probe, height: probe))
        canvas.lockFocus()
        logo.draw(in: NSRect(x: 0, y: 0, width: probe, height: probe))
        canvas.unlockFocus()

        guard let tiff = canvas.tiffRepresentation,
              let raster = NSBitmapImageRep(data: tiff),
              let pixels = raster.bitmapData
        else { return nil }

        let bytesPerPixel = raster.bitsPerPixel / 8
        var minX = raster.pixelsWide, maxX = -1
        var minY = raster.pixelsHigh, maxY = -1
        for y in 0..<raster.pixelsHigh {
            let row = pixels + y * raster.bytesPerRow
            for x in 0..<raster.pixelsWide where row[x * bytesPerPixel + bytesPerPixel - 1] > 0 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        let width = Double(raster.pixelsWide), height = Double(raster.pixelsHigh)
        return NSRect(
            x: Double(minX) / width,
            // Raster rows run top-down; flip into AppKit's bottom-up coordinates.
            y: Double(raster.pixelsHigh - 1 - maxY) / height,
            width: Double(maxX - minX + 1) / width,
            height: Double(maxY - minY + 1) / height
        )
    }
}
