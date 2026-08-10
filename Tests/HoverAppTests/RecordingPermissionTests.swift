import Foundation
import HoverCore
import HoverPlatform
import Testing

@testable import HoverApp

/// The permission gate in front of a recording: what Hover asks, when it asks
/// it, and what it records once the user has answered. Driven with
/// ``FakeRecordingPermissions`` — this Mac's real privacy settings are never
/// read, so the suite behaves the same on a fresh machine as on a set-up one.
@Suite @MainActor struct RecordingPermissionTests {

    private func makeEngine(
        permissions: FakeRecordingPermissions,
        capture: FakeAudioCapture = FakeAudioCapture(),
        inputSource: InputSource = .both
    ) -> RecordingModel {
        RecordingModel(
            transcriber: FakeTranscriber(result: "hello"),
            audioCapture: capture,
            transcriptStore: FakeTranscriptStore(),
            settings: InMemorySettings(inputSource: inputSource),
            permissions: permissions,
            speakerDiarizer: FakeSpeakerDiarizer(turns: [])
        )
    }

    // MARK: Asking before recording

    @Test func recordingStartsWithNoQuestionsWhenEverythingIsAllowed() async {
        let capture = FakeAudioCapture()
        let engine = makeEngine(permissions: FakeRecordingPermissions(), capture: capture)

        await engine.startRecording()

        #expect(engine.isRecording)
        #expect(engine.permissionRequest == nil)
        #expect(await capture.startedInputSource == .both)
    }

    /// The bug this whole flow exists for: Hover used to trigger the macOS
    /// prompt from inside capture and report the refusal in the same breath,
    /// over a recording that had already started mic-only.
    @Test func firstRunAsksAboutSystemAudioInsteadOfRecordingHalfOfIt() async {
        let permissions = FakeRecordingPermissions(screenRecording: .notRequested)
        let capture = FakeAudioCapture()
        let engine = makeEngine(permissions: permissions, capture: capture)

        await engine.startRecording()

        #expect(!engine.isRecording)
        #expect(await capture.startedInputSource == nil)
        #expect(engine.permissionRequest?.reason == .screenRecordingNotRequested)
        // Explained first — the system prompt only fires once the user says yes.
        #expect(permissions.screenRecordingRequests == 0)
        // And no alert: nothing has gone wrong yet.
        #expect(engine.presentedFailureMessage == nil)
    }

    @Test func aRefusedScreenRecordingPointsAtSystemSettings() async {
        let permissions = FakeRecordingPermissions(screenRecording: .denied)
        let engine = makeEngine(permissions: permissions)

        await engine.startRecording()

        #expect(!engine.isRecording)
        #expect(engine.permissionRequest?.reason == .screenRecordingRefused)
        #expect(engine.permissionRequest?.fallback == .microphone)
    }

    @Test func systemOnlyModeHasNothingToFallBackOn() async {
        let permissions = FakeRecordingPermissions(screenRecording: .denied)
        let engine = makeEngine(permissions: permissions, inputSource: .system)

        await engine.startRecording()

        #expect(!engine.isRecording)
        #expect(engine.permissionRequest?.fallback == nil)
        #expect(engine.permissionRequest?.fallbackButton == nil)
    }

    @Test func askingIsSkippedForTheMicrophoneOnlyMode() async {
        let permissions = FakeRecordingPermissions(screenRecording: .denied)
        let capture = FakeAudioCapture()
        let engine = makeEngine(
            permissions: permissions, capture: capture, inputSource: .microphone)

        await engine.startRecording()

        #expect(engine.isRecording)
        #expect(engine.permissionRequest == nil)
        #expect(await capture.startedInputSource == .microphone)
    }

    /// A question the user hasn't answered must not cost them the transcript
    /// that is still on screen from the last recording.
    @Test func askingLeavesTheCurrentTranscriptAlone() async {
        let permissions = FakeRecordingPermissions(screenRecording: .notRequested)
        let engine = makeEngine(permissions: permissions)
        engine.committedChunks = ["from the last recording"]

        await engine.startRecording()

        #expect(engine.committedChunks == ["from the last recording"])
    }

    // MARK: The microphone

    @Test func theMicrophonePromptIsShownWithoutBeingExplainedFirst() async {
        let permissions = FakeRecordingPermissions(microphone: .notRequested)
        permissions.microphoneAnswer = .granted
        let engine = makeEngine(permissions: permissions)

        await engine.startRecording()

        #expect(permissions.microphoneRequests == 1)
        #expect(engine.isRecording)
        #expect(engine.permissionRequest == nil)
    }

    @Test func aRefusedMicrophoneStopsHoverFromRecordingSilence() async {
        let permissions = FakeRecordingPermissions(microphone: .notRequested)
        permissions.microphoneAnswer = .denied
        let capture = FakeAudioCapture()
        let engine = makeEngine(
            permissions: permissions, capture: capture, inputSource: .microphone)

        await engine.startRecording()

        #expect(!engine.isRecording)
        #expect(await capture.startedInputSource == nil)
        #expect(engine.permissionRequest?.reason == .microphoneRefused)
        #expect(engine.permissionRequest?.fallback == nil)
    }

    @Test func aRefusedMicrophoneStillOffersSystemAudioWhenThatIsAllowed() async {
        let permissions = FakeRecordingPermissions(microphone: .denied, screenRecording: .granted)
        let engine = makeEngine(permissions: permissions)

        await engine.startRecording()

        #expect(engine.permissionRequest?.reason == .microphoneRefused)
        #expect(engine.permissionRequest?.fallback == .system)
    }

    /// Offering system audio as the way out would just walk the user into a
    /// second permission dialog.
    @Test func aRefusedMicrophoneOffersNothingWhenSystemAudioIsAlsoUnavailable() async {
        let permissions = FakeRecordingPermissions(
            microphone: .denied, screenRecording: .notRequested)
        let engine = makeEngine(permissions: permissions)

        await engine.startRecording()

        #expect(engine.permissionRequest?.fallback == nil)
    }

    // MARK: Answering

    @Test func recordingWithReducedInputCapturesWhatIsAllowed() async {
        let permissions = FakeRecordingPermissions(screenRecording: .denied)
        let capture = FakeAudioCapture()
        let engine = makeEngine(permissions: permissions, capture: capture)
        await engine.startRecording()

        await engine.recordWithReducedInput()

        #expect(engine.isRecording)
        #expect(engine.permissionRequest == nil)
        #expect(await capture.startedInputSource == .microphone)
        #expect(engine.activeInputSource == .microphone)
    }

    /// Going ahead once is not a change of mind about the preference — the
    /// next recording should try for system audio again.
    @Test func recordingWithReducedInputLeavesThePreferenceAlone() async {
        let permissions = FakeRecordingPermissions(screenRecording: .denied)
        let settings = InMemorySettings(inputSource: .both)
        let engine = RecordingModel(
            transcriber: FakeTranscriber(result: "hello"),
            audioCapture: FakeAudioCapture(),
            transcriptStore: FakeTranscriptStore(),
            settings: settings,
            permissions: permissions,
            speakerDiarizer: FakeSpeakerDiarizer(turns: [])
        )
        await engine.startRecording()

        await engine.recordWithReducedInput()

        #expect(engine.inputSource == .both)
        #expect(settings.inputSource == .both)
    }

    /// A newly granted System Audio permission may require a fresh app process,
    /// so the ask has to end in a restart offer rather than in
    /// "then relaunch" buried in a paragraph.
    @Test func allowingScreenRecordingLeadsToTheRestartMacOSRequires() async {
        let permissions = FakeRecordingPermissions(screenRecording: .notRequested)
        let engine = makeEngine(permissions: permissions)
        await engine.startRecording()

        engine.grantPermission()

        #expect(permissions.screenRecordingRequests == 1)
        #expect(engine.permissionRequest?.reason == .screenRecordingNeedsRelaunch)

        engine.grantPermission()

        #expect(permissions.relaunches == 1)
    }

    @Test func fixingARefusalOpensTheRightSettingsPane() async {
        let permissions = FakeRecordingPermissions(screenRecording: .denied)
        let engine = makeEngine(permissions: permissions)
        await engine.startRecording()

        engine.grantPermission()

        #expect(permissions.settingsOpened == [.screenRecording])
        #expect(engine.permissionRequest?.reason == .screenRecordingNeedsRelaunch)
    }

    @Test func fixingTheMicrophoneOpensSettingsAndClosesTheQuestion() async {
        let permissions = FakeRecordingPermissions(microphone: .denied)
        let engine = makeEngine(permissions: permissions, inputSource: .microphone)
        await engine.startRecording()

        engine.grantPermission()

        #expect(permissions.settingsOpened == [.microphone])
        #expect(engine.permissionRequest == nil)
    }

    @Test func dismissingTheQuestionRecordsNothing() async {
        let permissions = FakeRecordingPermissions(screenRecording: .notRequested)
        let capture = FakeAudioCapture()
        let engine = makeEngine(permissions: permissions, capture: capture)
        await engine.startRecording()

        engine.dismissPermissionRequest()

        #expect(engine.permissionRequest == nil)
        #expect(!engine.isRecording)
        #expect(await capture.startedInputSource == nil)
    }

    @Test func stalePermissionAnswerCannotStartANewerRequest() async throws {
        let permissions = FakeRecordingPermissions(screenRecording: .denied)
        let capture = FakeAudioCapture()
        let engine = makeEngine(permissions: permissions, capture: capture)
        await engine.startRecording()
        let firstRequestID = try #require(engine.permissionRequest?.id)
        engine.dismissPermissionRequest(requestID: firstRequestID)

        await engine.startRecording()
        let secondRequestID = try #require(engine.permissionRequest?.id)
        #expect(secondRequestID != firstRequestID)

        await engine.recordWithReducedInput(requestID: firstRequestID)

        #expect(!engine.isRecording)
        #expect(engine.permissionRequest?.id == secondRequestID)
        #expect(await capture.startCount == 0)
    }

    // MARK: Wording

    @Test func everyQuestionOffersAWayForward() {
        let reasons: [RecordingPermissionRequest.Reason] = [
            .screenRecordingNotRequested,
            .screenRecordingRefused,
            .screenRecordingNeedsRelaunch,
            .microphoneRefused,
        ]
        for reason in reasons {
            let request = RecordingPermissionRequest(reason: reason, fallback: .microphone)
            #expect(!request.title.isEmpty)
            #expect(!request.message.isEmpty)
            #expect(!request.primaryButton.isEmpty)
            #expect(request.fallbackButton == "Mic only")
            #expect(!request.consoleSummary.contains("\n"), "Agent Mode prints this on one line")
        }
    }

    @Test func systemAudioPermissionCopyNamesTheAudioOnlyCategory() {
        let firstRequest = RecordingPermissionRequest(
            reason: .screenRecordingNotRequested,
            fallback: .microphone
        )
        let refusedRequest = RecordingPermissionRequest(
            reason: .screenRecordingRefused,
            fallback: .microphone
        )

        #expect(firstRequest.title == "Include system audio?")
        #expect(firstRequest.message.contains("System Audio Recording Only"))
        #expect(refusedRequest.title == "System audio access is off")
        #expect(refusedRequest.message.contains("System Audio Recording Only"))
    }
}
