import Foundation
import HoverCore
import HoverPlatform

/// Root-only dependency composition. Feature models receive only the exact
/// collaborators selected for them.
@MainActor
struct AppDependencies {
    let settings: any SettingsStore
    let transcriptStore: any TranscriptStore
    let vaultFinder: any VaultFinder
    let permissions: any RecordingPermissions
    let modelSetup: any ModelSetup
    let transcriber: any Transcriber
    let makeAudioCapture: @Sendable () -> any AudioCapture
    let speakerDiarizer: any SpeakerDiarizer
    let recordingConfiguration: RecordingConfiguration

    static func live() -> AppDependencies {
        let layout = InstallLayout.current
        let configuration = RecordingConfiguration.default
        return AppDependencies(
            settings: UserDefaultsSettings(),
            transcriptStore: FileTranscriptStore(),
            vaultFinder: ObsidianVaultFinder(),
            permissions: SystemRecordingPermissions(),
            modelSetup: NetworkedModelSetup(modelsDirectory: layout.modelsDirectory),
            transcriber: WhisperCLITranscriber(
                layout: layout,
                log: HoverLog.transcription
            ),
            makeAudioCapture: {
                LiveAudioCapture(
                    configuration: configuration,
                    log: HoverLog.audioCapture
                )
            },
            speakerDiarizer: LocalSpeakerDiarizer(layout: layout),
            recordingConfiguration: configuration
        )
    }

    func makeRecordingModel() -> RecordingModel {
        RecordingModel(
            configuration: recordingConfiguration,
            transcriber: transcriber,
            audioCapture: makeAudioCapture(),
            transcriptStore: transcriptStore,
            settings: settings,
            permissions: permissions,
            speakerDiarizer: speakerDiarizer
        )
    }

    func makeTranscriptLibraryModel() -> TranscriptLibraryModel {
        TranscriptLibraryModel(
            transcriptStore: transcriptStore,
            settings: settings,
            vaultFinder: vaultFinder,
            log: HoverLog.storage
        )
    }

    func makeAppModel() -> AppModel {
        AppModel(
            recording: makeRecordingModel(),
            transcriptLibrary: makeTranscriptLibraryModel(),
            modelSetup: ModelSetupController(modelSetup: modelSetup)
        )
    }
}
