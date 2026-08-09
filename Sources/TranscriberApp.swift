import SwiftUI

/// The normal GUI app. Launched by ``HoverMain`` when no CLI flags are present.
/// (Agent/headless runs go through ``HoverCLI`` instead.)
struct TranscriberApp: App {
    @State private var engine = TranscriberEngine()
    @State private var menuBarMoth = MenuBarMoth()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(engine)
                .tint(BrandColors.orange)
                .frame(minWidth: 600, minHeight: 400)
                .onAppear {
                    setupHotKeys()
                    menuBarMoth.show(onClick: showWindow)
                    menuBarMoth.follow(engine)
                }
        }
        .defaultSize(width: 860, height: 560)

        Settings {
            InstallCLIView(isOnboarding: false)
        }
    }

    /// Clicking the moth brings Hover back to the front — handy once the window
    /// is buried behind whatever you're actually recording.
    private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }

    private func setupHotKeys() {
        HotKeys.shared.onStart = {
            NSApp.activate(ignoringOtherApps: true)
            Task { @MainActor in
                if engine.isRecording {
                    engine.stopRecording()
                }
                engine.clearMarkedTranscripts()
                engine.lastRecordingTranscript = nil
                await engine.startRecording()
            }
        }
        HotKeys.shared.onStop = {
            Task { @MainActor in
                if engine.isRecording {
                    engine.stopRecording()
                }
            }
        }
        HotKeys.shared.register()
    }
}
