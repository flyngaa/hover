import HoverCore
import Observation
import SwiftUI

/// The normal GUI app. Launched by ``HoverMain`` when no CLI flags are present.
/// (Agent/headless runs go through ``HoverCLI`` instead.)
struct HoverApp: App {
    @State private var appModel: AppModel
    @State private var statusItemController = StatusItemController()

    init() {
        _appModel = State(initialValue: AppDependencies.live().makeAppModel())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
                .environment(appModel.recording)
                .environment(appModel.transcriptLibrary)
                .environment(appModel.modelSetup)
                .tint(BrandColors.orange)
                .frame(minWidth: 600, minHeight: 400)
                .onAppear {
                    setupHotKeys()
                    // Only park a moth when no other Hover (a headless `hover
                    // record`, or a second copy) is already showing one, so the
                    // menu bar never sprouts two.
                    if !HoverCLI.anotherHoverInstanceIsRunning() {
                        statusItemController.show { command in
                            if command == .showWindow { showWindow() }
                        }
                    }
                    trackStatusItemSnapshot()
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
        RecordingHotKeyController.shared.onStart = {
            NSApp.activate(ignoringOtherApps: true)
            Task { @MainActor in
                if appModel.recording.isRecordingBusy {
                    await appModel.stopRecording()
                }
                await appModel.startRecording()
            }
        }
        RecordingHotKeyController.shared.onStop = {
            Task { @MainActor in
                if appModel.recording.canStopRecording {
                    await appModel.stopRecording()
                }
            }
        }
        RecordingHotKeyController.shared.register()
    }

    private func trackStatusItemSnapshot() {
        statusItemController.render(appModel.statusItemSnapshot)
        withObservationTracking {
            _ = appModel.statusItemSnapshot
        } onChange: {
            Task { @MainActor in trackStatusItemSnapshot() }
        }
    }
}
