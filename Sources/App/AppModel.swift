import Foundation
import HoverCore
import Observation

struct StatusItemSnapshot: Equatable, Sendable {
    enum Activity: Equatable, Sendable {
        case idle
        case recording
        case processing
    }

    let activity: Activity
    let tooltip: String
}

struct PresentedAlert: Identifiable, Equatable, Sendable {
    let id = UUID()
    let title: String
    let message: String
}

/// Thin cross-feature coordinator exposed by the GUI composition root.
@MainActor @Observable
final class AppModel {
    let recording: RecordingModel
    let transcriptLibrary: TranscriptLibraryModel
    let modelSetup: ModelSetupController
    var presentedAlert: PresentedAlert?

    static let modelSetupIncompleteReason =
        "Hover still needs to install the transcription model before it can transcribe. "
        + "Wait for setup to finish, or tap Retry if it failed."

    init(
        recording: RecordingModel,
        transcriptLibrary: TranscriptLibraryModel,
        modelSetup: ModelSetupController
    ) {
        self.recording = recording
        self.transcriptLibrary = transcriptLibrary
        self.modelSetup = modelSetup
    }

    var readiness: ApplicationReadiness {
        guard modelSetup.isComplete else {
            if case .failed(let message) = modelSetup.status {
                return .unavailable(RecordingFailure(kind: .notReady, message: message))
            }
            return .settingUpModels(modelSetup.status)
        }
        switch recording.capabilities {
        case .success(let capabilities):
            return .ready(capabilities)
        case .failure(let failure):
            return .unavailable(failure)
        }
    }

    var statusItemSnapshot: StatusItemSnapshot {
        let activity: StatusItemSnapshot.Activity
        if recording.isRecording {
            activity = .recording
        } else if recording.isFinalizingRecording {
            activity = .processing
        } else {
            activity = .idle
        }
        let tooltip: String
        switch activity {
        case .idle: tooltip = "Hover"
        case .recording: tooltip = "Hover — recording"
        case .processing: tooltip = "Hover — processing"
        }
        return StatusItemSnapshot(activity: activity, tooltip: tooltip)
    }

    @discardableResult
    func startRecording() async -> Bool {
        switch readiness {
        case .ready:
            break
        case .checking, .settingUpModels:
            presentRecordingFailure(Self.modelSetupIncompleteReason)
            return false
        case .unavailable(let failure):
            presentRecordingFailure(failure.message)
            return false
        }

        let started = await recording.startRecording(
            outputDirectory: transcriptLibrary.outputDirectory
        )
        if started { transcriptLibrary.clearMarkedTranscripts() }
        if let message = recording.presentedFailureMessage { presentRecordingFailure(message) }
        return started
    }

    @discardableResult
    func stopRecording() async -> SavedTranscript? {
        guard let result = await recording.stopRecording() else { return nil }
        let saved = transcriptLibrary.recordingDidFinish(result)
        if let message = recording.presentedFailureMessage { presentRecordingFailure(message) }
        return saved
    }

    func recordWithReducedInput(requestID: UUID? = nil) async {
        await recording.recordWithReducedInput(requestID: requestID)
        if recording.isRecording { transcriptLibrary.clearMarkedTranscripts() }
    }

    func requestOutputChange(to destination: OutputDestination) {
        guard recording.canConfigureRecording else { return }
        transcriptLibrary.requestOutputChange(to: destination)
    }

    func requestOutputChange(toFolder url: URL) {
        guard recording.canConfigureRecording else { return }
        transcriptLibrary.requestOutputChange(toFolder: url)
    }

    func resolvePendingOutputChange(movingTranscripts: Bool) {
        if let warning = transcriptLibrary.resolvePendingOutputChange(
            movingTranscripts: movingTranscripts
        ) {
            presentedAlert = PresentedAlert(
                title: "Some transcripts weren't moved",
                message: warning
            )
        }
    }

    func dismissAlert() {
        presentedAlert = nil
        recording.presentedFailureMessage = nil
    }

    private func presentRecordingFailure(_ message: String) {
        recording.presentedFailureMessage = message
        presentedAlert = PresentedAlert(title: "Something went wrong", message: message)
    }
}
