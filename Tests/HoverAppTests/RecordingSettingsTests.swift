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
            permissions: FakeRecordingPermissions(),
            speakerDiarizer: FakeSpeakerDiarizer(turns: [])
        )
    }

    @Test func engineLoadsSettingsOnInit() {
        let settings = InMemorySettings(
            inputSource: .microphone,
            diarizeSpeakers: true
        )
        let engine = makeEngine(settings: settings)
        #expect(engine.inputSource == .microphone)
        #expect(engine.diarizeSpeakers == true)
    }

    @Test func engineWritesChangesBackToStore() {
        let settings = InMemorySettings()
        let engine = makeEngine(settings: settings)

        engine.diarizeSpeakers = true
        engine.inputSource = .system

        #expect(settings.diarizeSpeakers == true)
        #expect(settings.inputSource == .system)
    }
}
