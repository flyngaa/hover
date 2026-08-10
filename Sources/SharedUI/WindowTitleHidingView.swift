import AppKit
import HoverCore
import SwiftUI

/// Keeps the window title hidden. SwiftUI otherwise keeps resetting the title
/// back to the app name whenever it re-renders (e.g. when a menu opens), so we
/// observe window updates and re-hide it each time.
@MainActor
struct WindowTitleHidingView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.attach(to: nsView.window) }
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var window: NSWindow?

        func attach(to window: NSWindow?) {
            guard let window else { return }
            hide(window)

            guard window !== self.window else { return }
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didUpdateNotification,
                object: self.window
            )
            self.window = window
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidUpdate(_:)),
                name: NSWindow.didUpdateNotification,
                object: window
            )
        }

        @objc private func windowDidUpdate(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            hide(window)
        }

        private func hide(_ window: NSWindow) {
            if window.titleVisibility != .hidden {
                window.titleVisibility = .hidden
            }
            if !window.title.isEmpty {
                window.title = ""
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
