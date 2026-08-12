import Foundation
import HoverCore
import HoverPlatform
import Testing

@testable import HoverApp

@Suite @MainActor struct AppModelTests {
    @Test func acceptedRecordingClearsSelectionAndReconcilesExactResult() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hover-app-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let settings = InMemorySettings(outputDirectoryPath: directory.path)
        let store = FileTranscriptStore()
        let recording = RecordingModel(
            transcriber: FakeTranscriber(result: "hello"),
            audioCapture: FakeAudioCapture(
                chunkOnStop: AudioChunk(samples: [0.5], startTime: 0, endTime: 1)
            ),
            transcriptStore: store,
            settings: settings,
            permissions: FakeRecordingPermissions()
        )
        let library = TranscriptLibraryModel(
            transcriptStore: store,
            settings: settings,
            vaultFinder: FakeVaultFinder()
        )
        library.markAll(ids: ["old-selection"])
        let appModel = AppModel(
            recording: recording,
            transcriptLibrary: library,
            modelSetup: ModelSetupController(modelSetup: FakeModelSetup(isComplete: true))
        )

        #expect(await appModel.startRecording())
        #expect(library.markedTranscriptIDs.isEmpty)

        let saved = await appModel.stopRecording()

        #expect(saved?.path == recording.lastResult?.path)
        #expect(library.lastRecordingTranscript == saved)
        #expect(library.savedTranscripts == [saved].compactMap { $0 })
    }
}
