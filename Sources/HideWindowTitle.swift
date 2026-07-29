import AppKit
import SwiftUI

/// Keeps the window title hidden. SwiftUI otherwise keeps resetting the title
/// back to the app name whenever it re-renders (e.g. when a menu opens), so we
/// observe window updates and re-hide it each time.
struct HideWindowTitle: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.attach(to: nsView.window) }
    }

    final class Coordinator {
        private weak var window: NSWindow?
        private var observer: NSObjectProtocol?

        func attach(to window: NSWindow?) {
            guard let window else { return }
            hide(window)

            guard window !== self.window else { return }
            self.window = window

            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.hide(window)
            }
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
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
