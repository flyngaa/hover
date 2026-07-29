import SwiftUI

/// The normal GUI app. Launched by ``HoverMain`` when no CLI flags are present.
/// (Agent/headless runs go through ``HoverCLI`` instead.)
struct TranscriberApp: App {
    @State private var engine = TranscriberEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(engine)
                .tint(BrandColors.orange)
                .frame(minWidth: 600, minHeight: 400)
                .onAppear {
                    setupHotKeys()
                }
        }
        .defaultSize(width: 860, height: 560)
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
