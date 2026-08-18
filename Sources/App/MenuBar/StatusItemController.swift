import AppKit
import HoverCore

/// The moth Hover parks in the macOS menu bar for as long as it's running. It
/// wears the usual menu bar black/white when idle and turns a soft blue while a
/// recording is in progress, so you can tell at a glance whether Hover is
/// listening — including in Agent Mode, where there is no window or dock icon
/// to look at.
///
/// An `NSObject` because the status item reaches it through target/action.
@MainActor
final class StatusItemController: NSObject {

    /// The colour the moth wears while recording — a pastel blue that reads as
    /// "live" without the alarm of red, and stays legible on light and dark
    /// menu bars alike.
    private static let recordingTint = NSColor(
        srgbRed: 0.42, green: 0.66, blue: 0.96, alpha: 1
    )

    enum Command: Equatable, Sendable, Hashable {
        case startRecording
        case stopRecording
        case showWindow
    }

    /// One row of the moth's dropdown. `command` is nil for the state header,
    /// which is shown disabled.
    struct MenuItemModel: Equatable {
        let title: String
        let isEnabled: Bool
        let command: Command?
    }

    /// Height of the moth in the menu bar, in points. The artwork is roughly
    /// twice as wide as it is tall, so pinning the *height* is what keeps it in
    /// proportion with the system's own menu bar icons; the width follows.
    private static let height = 15.0

    private var statusItem: NSStatusItem?
    private var onCommand: ((Command) -> Void)?
    private var supported: Set<Command> = []
    private(set) var snapshot = StatusItemSnapshot(activity: .idle, tooltip: "Hover")

    /// Renders a typed projection. The controller never observes or retains an
    /// application model, which keeps AppKit ownership at the composition edge.
    func render(_ snapshot: StatusItemSnapshot) {
        guard snapshot != self.snapshot else { return }
        self.snapshot = snapshot
        applyMothImage()
        // The dropdown carries the live state ("Recording…"/"Transcribing…") and
        // enables Start/Stop by it, so it has to be rebuilt on every change.
        rebuildMenu()
    }

    /// Puts the moth in the menu bar with a dropdown control menu. `supporting`
    /// declares which commands this host can carry out — the GUI can start, stop,
    /// and show its window; a headless `hover record` can only stop. Calling this
    /// again is a no-op: we only ever want one moth up there.
    func show(
        supporting commands: Set<Command> = [.showWindow],
        onCommand: ((Command) -> Void)? = nil
    ) {
        guard statusItem == nil else { return }
        self.onCommand = onCommand
        self.supported = commands

        // Variable length: the moth is wider than the square slot a status item
        // gets by default, which would otherwise clip its wings.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        applyMothImage()
        rebuildMenu()
    }

    private func applyMothImage() {
        // A template image lets macOS colour the moth itself — black on a light
        // menu bar, white on a dark one, inverted while the item is pressed.
        // The recording moth opts out of that so it can wear its own blue.
        let isRecording = snapshot.activity == .recording
        statusItem?.button?.image = MothArtwork.image(
            height: Self.height,
            tint: isRecording ? Self.recordingTint : nil
        )
        statusItem?.button?.image?.isTemplate = !isRecording
        statusItem?.button?.toolTip = snapshot.tooltip
    }

    // MARK: - Dropdown

    /// The rows the dropdown should show for `activity`, given what the host
    /// `supports`. Pure so the layout and enablement can be tested without a
    /// status bar.
    static func menuModel(
        activity: StatusItemSnapshot.Activity,
        supports: Set<Command>
    ) -> [MenuItemModel] {
        var items = [MenuItemModel(title: header(for: activity), isEnabled: false, command: nil)]
        if supports.contains(.startRecording) {
            items.append(
                MenuItemModel(
                    title: "Start Recording",
                    isEnabled: activity == .idle,
                    command: .startRecording
                ))
        }
        if supports.contains(.stopRecording) {
            items.append(
                MenuItemModel(
                    title: "Stop Recording",
                    isEnabled: activity == .recording,
                    command: .stopRecording
                ))
        }
        if supports.contains(.showWindow) {
            items.append(
                MenuItemModel(title: "Show Hover", isEnabled: true, command: .showWindow))
        }
        return items
    }

    private static func header(for activity: StatusItemSnapshot.Activity) -> String {
        switch activity {
        case .idle: return "Hover — Ready"
        case .recording: return "Recording…"
        case .processing: return "Transcribing…"
        }
    }

    private func rebuildMenu() {
        guard let statusItem, !supported.isEmpty else {
            statusItem?.menu = nil
            return
        }
        let menu = NSMenu()
        // Our models already decide what's enabled; let them stand rather than
        // AppKit's target/action auto-validation.
        menu.autoenablesItems = false

        for (index, model) in Self.menuModel(activity: snapshot.activity, supports: supported)
            .enumerated()
        {
            // A rule under the state header, and before "Show Hover", groups the
            // controls without labelling every divider.
            if index == 1 || model.command == .showWindow {
                menu.addItem(.separator())
            }
            let item = NSMenuItem(
                title: model.title,
                action: model.command == nil ? nil : #selector(menuItemClicked(_:)),
                keyEquivalent: ""
            )
            item.isEnabled = model.isEnabled
            item.target = self
            item.representedObject = model.command
            menu.addItem(item)
        }
        statusItem.menu = menu
    }

    @objc private func menuItemClicked(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? Command else { return }
        onCommand?(command)
    }
}

/// Draws the moth logo at menu bar size.
///
/// The logo is a wide moth sitting in the middle of a large square canvas, so
/// most of the file is empty space. Dropped into the menu bar as-is the moth
/// would shrink to a smudge, so we measure where the artwork actually is and
/// scale the canvas up until the moth alone fills the space we want.
@MainActor
private enum MothArtwork {

    /// The logo plus the tight bounds of the moth within it, expressed as a
    /// fraction of the canvas. Loaded once — measuring means rasterising, and
    /// the answer never changes while the app runs.
    private static let moth: (logo: NSImage, bounds: NSRect)? = {
        guard let url = Bundle.main.url(forResource: "hover", withExtension: "svg"),
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
        var minX = raster.pixelsWide
        var maxX = -1
        var minY = raster.pixelsHigh
        var maxY = -1
        for y in 0..<raster.pixelsHigh {
            let row = pixels + y * raster.bytesPerRow
            for x in 0..<raster.pixelsWide where row[x * bytesPerPixel + bytesPerPixel - 1] > 0 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        let width = Double(raster.pixelsWide)
        let height = Double(raster.pixelsHigh)
        return NSRect(
            x: Double(minX) / width,
            // Raster rows run top-down; flip into AppKit's bottom-up coordinates.
            y: Double(raster.pixelsHigh - 1 - maxY) / height,
            width: Double(maxX - minX + 1) / width,
            height: Double(maxY - minY + 1) / height
        )
    }
}
