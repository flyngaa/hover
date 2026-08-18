import HoverCore
import Observation
import SwiftUI

/// The normal GUI app. Launched by ``HoverMain`` when no CLI flags are present.
/// (Agent/headless runs go through ``HoverCLI`` instead.)
struct HoverApp: App {
    @State private var appModel: AppModel
    @State private var statusItemController = StatusItemController()
    @State private var presence = RecordingPresence()
    @State private var ownsMoth = false

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
                    ownsMoth = !HoverCLI.anotherHoverInstanceIsRunning()
                    if ownsMoth {
                        statusItemController.show { command in
                            if command == .showWindow { showWindow() }
                        }
                    }
                    // Re-render when a peer process (a headless run) changes state
                    // so this moth reflects any Hover recording, not just this one.
                    presence.onChange = { Task { @MainActor in renderMothState() } }
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
        renderMothState()
        withObservationTracking {
            _ = appModel.statusItemSnapshot
        } onChange: {
            Task { @MainActor in trackStatusItemSnapshot() }
        }
    }

    /// Announce this process's recording state to any peers, then — if this
    /// process owns the moth — render the state combined across every running
    /// Hover, so one moth speaks for the GUI and the headless CLI alike.
    private func renderMothState() {
        presence.announce(appModel.statusItemSnapshot.activity.presenceState)
        guard ownsMoth else { return }
        statusItemController.render(presence.combinedState.statusItemSnapshot)
    }
}
