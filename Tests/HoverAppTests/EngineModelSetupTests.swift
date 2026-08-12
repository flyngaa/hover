import Foundation
import HoverCore
import HoverPlatform
import Testing

@testable import HoverApp

/// Engine-level coverage of first-launch Model Setup: required vs skipped,
/// Retry after failure, recording refused while incomplete. Driven with
/// ``FakeModelSetup`` — no network, no model data on disk.
@Suite @MainActor struct EngineModelSetupTests {

    private func makeEngine(
        modelSetup: FakeModelSetup,
        capture: FakeAudioCapture = FakeAudioCapture(),
        settings: SettingsStore = InMemorySettings()
    ) -> AppModel {
        let store = FakeTranscriptStore()
        let recording = RecordingModel(
            transcriber: FakeTranscriber(result: "hello"),
            audioCapture: capture,
            transcriptStore: store,
            settings: settings,
            permissions: FakeRecordingPermissions()
        )
        let library = TranscriptLibraryModel(
            transcriptStore: store,
            settings: settings,
            vaultFinder: FakeVaultFinder()
        )
        return AppModel(
            recording: recording,
            transcriptLibrary: library,
            modelSetup: ModelSetupController(modelSetup: modelSetup)
        )
    }

    /// Wait until `modelSetupStatus` matches (or time out).
    private func waitForStatus(
        _ engine: AppModel,
        _ expected: ModelSetupStatus
    ) async -> ModelSetupStatus {
        for _ in 0..<200 {
            let current = await MainActor.run { engine.modelSetup.status }
            if current == expected { return current }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await MainActor.run { engine.modelSetup.status }
    }

    @Test func setupIsRequiredWhenModelDataIsMissing() {
        let setup = FakeModelSetup(isComplete: false)
        let engine = makeEngine(modelSetup: setup)

        #expect(engine.modelSetup.status != .notNeeded)
    }

    @Test func setupIsSkippedWhenWhisperModelIsPresent() {
        let setup = FakeModelSetup(isComplete: true)
        let engine = makeEngine(modelSetup: setup)

        #expect(engine.modelSetup.status == .notNeeded)
    }

    @Test func missingWhisperModelRequiresSetupAndFetchesIt() async {
        let setup = FakeModelSetup(present: [])
        let engine = makeEngine(modelSetup: setup)

        #expect(engine.modelSetup.status != .notNeeded)

        engine.modelSetup.startIfNeeded()
        #expect(await waitForStatus(engine, .notNeeded) == .notNeeded)
        #expect(setup.lastFetched == [.ggml])
        #expect(setup.fetchCount == 1)
    }

    @Test func failingFetchSurfacesAnErrorAndRetrySucceeds() async {
        let setup = FakeModelSetup(isComplete: false)
        setup.fetchError = ModelSetupError.fetchFailed("Network dropped.")
        let engine = makeEngine(modelSetup: setup)

        engine.modelSetup.startIfNeeded()
        #expect(
            await waitForStatus(engine, .failed(message: "Network dropped."))
                == .failed(message: "Network dropped.")
        )

        // Retry — the fake clears fetchError after one failure, so this succeeds.
        engine.modelSetup.retry()
        #expect(await waitForStatus(engine, .notNeeded) == .notNeeded)
        #expect(setup.fetchCount == 2)
        #expect(setup.isComplete)
    }

    @Test func successfulSetupClearsStateSoTheAppProceeds() async {
        let setup = FakeModelSetup(isComplete: false)
        let engine = makeEngine(modelSetup: setup)

        engine.modelSetup.startIfNeeded()
        #expect(await waitForStatus(engine, .notNeeded) == .notNeeded)
        #expect(setup.isComplete)
    }

    @Test func recordingIsRefusedWhileSetupIsIncomplete() async {
        let setup = FakeModelSetup(isComplete: false)
        let engine = makeEngine(modelSetup: setup)

        await engine.startRecording()

        #expect(!engine.recording.isRecording)
        #expect(engine.recording.presentedFailureMessage == AppModel.modelSetupIncompleteReason)
    }

    @Test func changingOutputDestinationDoesNotRetriggerSetup() throws {
        let setup = FakeModelSetup(isComplete: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hover-setup-dest-\(UUID().uuidString)")
        let current = root.appendingPathComponent("Current")
        let elsewhere = root.appendingPathComponent("Elsewhere")
        let vaultTranscripts =
            root
            .appendingPathComponent("Vault")
            .appendingPathComponent("Transcripts")
        for dir in [current, elsewhere, vaultTranscripts] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = makeEngine(
            modelSetup: setup,
            settings: InMemorySettings(outputDirectoryPath: current.path)
        )
        #expect(engine.modelSetup.status == .notNeeded)

        engine.requestOutputChange(
            to: OutputDestination(
                kind: .custom,
                name: elsewhere.lastPathComponent,
                directory: elsewhere
            )
        )
        #expect(engine.modelSetup.status == .notNeeded)

        // Choosing an Obsidian Vault as Output Destination must not bring setup
        // back either — model data and transcript storage stay separate.
        engine.requestOutputChange(
            to: OutputDestination(
                kind: .vault,
                name: "Vault",
                directory: vaultTranscripts
            )
        )

        #expect(engine.modelSetup.status == .notNeeded)
        #expect(setup.fetchCount == 0)
    }

    @Test func removingModelDataBringsSetupBack() {
        let setup = FakeModelSetup(isComplete: true)
        let engine = makeEngine(modelSetup: setup)
        #expect(engine.modelSetup.status == .notNeeded)

        // Simulate a deleted model file the way a relaunch would see it: a new
        // engine with incomplete Model Setup. Setup is required again.
        let afterDelete = FakeModelSetup(isComplete: false)
        let relaunched = makeEngine(modelSetup: afterDelete)
        #expect(relaunched.modelSetup.status != .notNeeded)
    }

    @Test func agentModeFailsFastWhenModelDataIsMissingWithoutFetching() {
        let setup = FakeModelSetup(isComplete: false)

        let reason = HoverCLI.modelDataMissingReason(for: setup)

        #expect(reason == HoverCLI.modelDataMissingMessage)
        #expect(reason?.contains("hover setup") == true)
        #expect(reason?.contains("Open Hover") == false)
        #expect(setup.fetchCount == 0)
    }

    @Test func agentModeProceedsWhenModelDataIsPresent() {
        let setup = FakeModelSetup(isComplete: true)

        #expect(HoverCLI.modelDataMissingReason(for: setup) == nil)
        #expect(setup.fetchCount == 0)
    }
}
