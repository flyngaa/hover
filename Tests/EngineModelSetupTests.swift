import Testing
import Foundation
@testable import TranscriberKit

/// Engine-level coverage of first-launch Model Setup: required vs skipped,
/// Retry after failure, recording refused while incomplete. Driven with
/// ``FakeModelSetup`` — no network, no model data on disk.
@Suite struct EngineModelSetupTests {

    private func makeEngine(
        modelSetup: FakeModelSetup,
        capture: FakeAudioCapture = FakeAudioCapture(),
        settings: SettingsStore = InMemorySettings()
    ) -> TranscriberEngine {
        TranscriberEngine(
            transcriber: FakeTranscriber(result: "hello"),
            audioCapture: capture,
            transcriptStore: FakeTranscriptStore(),
            vaultFinder: FakeVaultFinder(),
            settings: settings,
            permissions: FakeRecordingPermissions(),
            modelSetup: modelSetup
        )
    }

    /// Wait until `modelSetupStatus` matches (or time out).
    private func waitForStatus(
        _ engine: TranscriberEngine,
        _ expected: ModelSetupStatus
    ) async -> ModelSetupStatus {
        for _ in 0..<200 {
            let current = await MainActor.run { engine.modelSetupStatus }
            if current == expected { return current }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await MainActor.run { engine.modelSetupStatus }
    }

    @Test func setupIsRequiredWhenModelDataIsMissing() {
        let setup = FakeModelSetup(isComplete: false)
        let engine = makeEngine(modelSetup: setup)

        #expect(engine.modelSetupStatus != .notNeeded)
    }

    @Test func setupIsSkippedWhenAllThreeFilesArePresent() {
        let setup = FakeModelSetup(isComplete: true)
        let engine = makeEngine(modelSetup: setup)

        #expect(engine.modelSetupStatus == .notNeeded)
    }

    @Test func partialDataStillRequiresSetupAndFetchesOnlyGaps() async {
        let setup = FakeModelSetup(present: [.ggml])
        let engine = makeEngine(modelSetup: setup)

        #expect(engine.modelSetupStatus != .notNeeded)

        engine.beginModelSetup()
        #expect(await waitForStatus(engine, .notNeeded) == .notNeeded)
        #expect(setup.lastFetched == [.segmentation, .embedding])
        #expect(setup.fetchCount == 1)
    }

    @Test func failingFetchSurfacesAnErrorAndRetrySucceeds() async {
        let setup = FakeModelSetup(isComplete: false)
        setup.fetchError = ModelSetupError.fetchFailed("Network dropped.")
        let engine = makeEngine(modelSetup: setup)

        engine.beginModelSetup()
        #expect(
            await waitForStatus(engine, .failed(message: "Network dropped."))
                == .failed(message: "Network dropped.")
        )

        // Retry — the fake clears fetchError after one failure, so this succeeds.
        engine.beginModelSetup()
        #expect(await waitForStatus(engine, .notNeeded) == .notNeeded)
        #expect(setup.fetchCount == 2)
        #expect(setup.isComplete)
    }

    @Test func successfulSetupClearsStateSoTheAppProceeds() async {
        let setup = FakeModelSetup(isComplete: false)
        let engine = makeEngine(modelSetup: setup)

        engine.beginModelSetup()
        #expect(await waitForStatus(engine, .notNeeded) == .notNeeded)
        #expect(setup.isComplete)
    }

    @Test func recordingIsRefusedWhileSetupIsIncomplete() async {
        let setup = FakeModelSetup(isComplete: false)
        let engine = makeEngine(modelSetup: setup)

        await engine.startRecording()

        #expect(!engine.isRecording)
        #expect(engine.authError == TranscriberEngine.modelSetupIncompleteReason)
    }

    @Test func changingOutputDestinationDoesNotRetriggerSetup() throws {
        let setup = FakeModelSetup(isComplete: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hover-setup-dest-\(UUID().uuidString)")
        let current = root.appendingPathComponent("Current")
        let elsewhere = root.appendingPathComponent("Elsewhere")
        let vaultTranscripts = root
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
        #expect(engine.modelSetupStatus == .notNeeded)

        engine.requestOutputChange(
            to: OutputDestination(
                kind: .custom,
                name: elsewhere.lastPathComponent,
                directory: elsewhere
            )
        )
        #expect(engine.modelSetupStatus == .notNeeded)

        // Choosing an Obsidian Vault as Output Destination must not bring setup
        // back either — model data and transcript storage stay separate.
        engine.requestOutputChange(
            to: OutputDestination(
                kind: .vault,
                name: "Vault",
                directory: vaultTranscripts
            )
        )

        #expect(engine.modelSetupStatus == .notNeeded)
        #expect(setup.fetchCount == 0)
    }

    @Test func removingModelDataBringsSetupBack() {
        let setup = FakeModelSetup(isComplete: true)
        let engine = makeEngine(modelSetup: setup)
        #expect(engine.modelSetupStatus == .notNeeded)

        // Simulate a deleted model file the way a relaunch would see it: a new
        // engine with incomplete Model Setup. Setup is required again.
        let afterDelete = FakeModelSetup(isComplete: false)
        let relaunched = makeEngine(modelSetup: afterDelete)
        #expect(relaunched.modelSetupStatus != .notNeeded)
    }

    @Test func agentModeFailsFastWhenModelDataIsMissingWithoutFetching() {
        let setup = FakeModelSetup(isComplete: false)
        let engine = makeEngine(modelSetup: setup)

        let reason = HoverCLI.modelDataMissingReason(for: engine)

        #expect(reason == HoverCLI.modelDataMissingMessage)
        #expect(setup.fetchCount == 0)
    }

    @Test func agentModeProceedsWhenModelDataIsPresent() {
        let setup = FakeModelSetup(isComplete: true)
        let engine = makeEngine(modelSetup: setup)

        #expect(HoverCLI.modelDataMissingReason(for: engine) == nil)
        #expect(setup.fetchCount == 0)
    }
}
