import Foundation
import HoverCore
import Testing

@testable import HoverApp

/// Verifies that the recording feature loads from and writes through its
/// platform-independent Settings Store seam.
@Suite @MainActor struct RecordingSettingsTests {

    private func makeEngine(settings: SettingsStore) -> RecordingModel {
        RecordingModel(
            transcriber: FakeTranscriber(result: ""),
            audioCapture: FakeAudioCapture(),
            transcriptStore: FakeTranscriptStore(),
            settings: settings,
            permissions: FakeRecordingPermissions()
        )
    }

    @Test func engineLoadsSettingsOnInit() {
        let settings = InMemorySettings(inputSource: .microphone)
        let engine = makeEngine(settings: settings)
        #expect(engine.inputSource == .microphone)
    }

    @Test func engineWritesChangesBackToStore() {
        let settings = InMemorySettings()
        let engine = makeEngine(settings: settings)

        engine.inputSource = .system

        #expect(settings.inputSource == .system)
    }
}
