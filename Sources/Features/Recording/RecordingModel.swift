import Foundation
import HoverCore
import HoverPlatform
import Observation

/// Main-actor owner of recording presentation and permission state. The
/// ordered background workflow belongs to one `RecordingSession` actor.
@MainActor @Observable
final class RecordingModel {

    // MARK: - Observed state

    private(set) var recordingPhase: RecordingPhase = .idle
    var isRecording: Bool {
        if case .recording = recordingPhase { return true }
        return false
    }
    var isRecordingBusy: Bool {
        switch recordingPhase {
        case .checkingReadiness, .starting, .recording, .stopping, .processing, .cancelling:
            return true
        case .idle, .requestingPermission, .completed, .failed:
            return false
        }
    }
    var canConfigureRecording: Bool { !isRecordingBusy }
    var canStopRecording: Bool {
        switch recordingPhase {
        case .checkingReadiness, .starting, .recording:
            return true
        case .idle, .requestingPermission, .stopping, .processing, .completed,
            .cancelling, .failed:
            return false
        }
    }
    var isFinalizingRecording: Bool {
        switch recordingPhase {
        case .stopping, .processing:
            return true
        default:
            return false
        }
    }
    var recordingTitle: String? {
        switch recordingPhase {
        case .starting(let state), .recording(let state), .stopping(let state),
            .processing(let state, _), .cancelling(let state):
            return state.title
        case .idle, .checkingReadiness, .requestingPermission, .completed, .failed:
            return nil
        }
    }
    var committedChunks: [String] = []
    private(set) var lastResult: RecordingResult?
    var statusMessage = "Ready"
    var presentedFailureMessage: String?

    /// Set in place of starting a recording when macOS hasn't allowed what the
    /// user asked for. The UI shows it and answers it; see
    /// ``recordWithReducedInput()`` and ``grantPermission()``.
    var permissionRequest: RecordingPermissionRequest? {
        guard case .requestingPermission(_, let request) = recordingPhase else { return nil }
        return request
    }

    /// What the recording in progress is actually capturing. Differs from
    /// ``inputSource`` when the user chose to go ahead without a permission
    /// macOS hasn't granted — their preference is left as they set it.
    var activeInputSource: InputSource {
        switch recordingPhase {
        case .starting(let state), .recording(let state), .stopping(let state),
            .processing(let state, _), .cancelling(let state):
            return state.activeInputSource
        case .idle, .checkingReadiness, .requestingPermission, .completed, .failed:
            return inputSource
        }
    }

    // Persisted settings. The stored values below drive the UI (SwiftUI binds to
    // them); each change is written through the injected ``SettingsStore``, and
    // the initial values are loaded from it in `init`.

    var inputSource: InputSource = .both {
        didSet { settings.inputSource = inputSource }
    }

    /// Live / finished transcript body. May include `**Mic:**` / `**System:**`
    /// paragraphs when Both mode is labeling tracks.
    var committedText: String {
        // Prefer a single body string (track-labeled Markdown uses newlines);
        // fall back to space-joining for legacy multi-chunk lists.
        if committedChunks.count == 1 { return committedChunks[0] }
        return committedChunks.joined(separator: " ")
    }

    /// True after Stop while the finished recording is still being worked on
    /// (final chunk flush / save), before the transcript is ready.
    /// `recordingTitle` stays set through that pass; `isRecording` is already off.
    /// Drives the "processing" shimmer over the transcript text.
    var isProcessing: Bool {
        if case .processing = recordingPhase { return true }
        return false
    }

    var capabilities: Result<RecordingCapabilities, RecordingFailure> {
        if let reason = transcriber.unavailableReason {
            return .failure(RecordingFailure(kind: .unavailableTranscriber, message: reason))
        }
        return .success(RecordingCapabilities())
    }

    // MARK: - Configuration
    @ObservationIgnored private let configuration: RecordingConfiguration

    /// Turns captured audio samples into text. Injected so tests can supply a
    /// fake instead of the real `whisper-cli`.
    @ObservationIgnored let transcriber: Transcriber

    /// Captures audio and emits ready-to-transcribe chunks. Injected so tests
    /// can drive the engine with canned samples instead of real devices.
    @ObservationIgnored let audioCapture: AudioCapture

    /// Owns transcript files on disk (listing, search, rename/move/delete,
    /// markdown format). Injected so tests can use an in-memory fake.
    @ObservationIgnored let transcriptStore: TranscriptStore

    /// Persists user settings (input source, output folder). Injected so
    /// tests can use an in-memory store instead of the real `UserDefaults`.
    @ObservationIgnored let settings: SettingsStore

    /// What macOS allows Hover to hear. Injected so tests can drive the
    /// permission flows without touching this Mac's real privacy settings.
    @ObservationIgnored let permissions: RecordingPermissions

    // MARK: - Session state
    @ObservationIgnored private var currentSession: RecordingSession?
    @ObservationIgnored private var finalizationTask: Task<RecordingResult?, Never>?
    @ObservationIgnored private var pendingStopRequestID: UUID?
    @ObservationIgnored private var pendingStopWaiters:
        [UUID: [CheckedContinuation<RecordingResult?, Never>]] = [:]
    @ObservationIgnored var chunksTranscribed = 0

    init(
        configuration: RecordingConfiguration = .default,
        transcriber: any Transcriber,
        audioCapture: any AudioCapture,
        transcriptStore: any TranscriptStore,
        settings: any SettingsStore,
        permissions: any RecordingPermissions
    ) {
        self.configuration = configuration
        self.permissions = permissions
        self.transcriber = transcriber
        self.audioCapture = audioCapture
        self.transcriptStore = transcriptStore
        self.settings = settings

        // Load persisted settings. Assigning inside init doesn't fire the didSet
        // observers, so this reads without immediately writing back.
        inputSource = settings.inputSource
    }

    func log(_ msg: String) {
        HoverLog.recording(msg)
    }

    // MARK: - Recording lifecycle

    @discardableResult
    func startRecording(outputDirectory: URL = RecordingOutput.defaultDirectory) async -> Bool {
        switch recordingPhase {
        case .idle, .completed, .failed:
            break
        case .checkingReadiness, .requestingPermission, .starting, .recording,
            .stopping, .processing, .cancelling:
            return false
        }

        let request = RecordingRequest(
            inputSource: inputSource,
            outputDirectory: outputDirectory
        )
        presentedFailureMessage = nil
        recordingPhase = .checkingReadiness(request)

        if case .failure(let failure) = capabilities {
            failRecording(requestID: request.id, failure: failure)
            return false
        }

        // Settle permissions before anything is cleared or started: a recording
        // that doesn't happen shouldn't wipe the transcript on screen, and the
        // user shouldn't be told what macOS refused while the system prompt is
        // still on screen unanswered.
        let permittedSource = await permittedInputSource(for: request)
        guard pendingStopRequestID != request.id else {
            recordingPhase = .idle
            resolvePendingStops(for: request.id, with: lastResult)
            return false
        }
        guard let source = permittedSource else { return false }

        return await beginRecording(request, using: source)
    }

    /// What Hover may actually record with, given what macOS allows.
    ///
    /// `nil` means the user has to answer something first: ``permissionRequest``
    /// then holds the question, and the answer comes back through
    /// ``recordWithReducedInput()`` or ``grantPermission()``.
    private func permittedInputSource(for request: RecordingRequest) async -> InputSource? {
        let requested = request.inputSource
        if requested != .system {
            var microphone = permissions.microphone
            // Worth prompting for unasked: it's the one permission an audio
            // recorder plainly needs, and macOS applies the answer at once.
            if microphone == .notRequested {
                microphone = await permissions.requestMicrophone()
            }
            guard pendingStopRequestID != request.id else { return nil }
            if microphone == .denied {
                // System audio alone is still a recording worth having, but only
                // if macOS already allows it — don't stack two permission asks.
                let fallback: InputSource? =
                    requested == .both && permissions.screenRecording == .granted ? .system : nil
                ask(.microphoneRefused, fallback: fallback, for: request)
                return nil
            }
        }

        guard pendingStopRequestID != request.id else { return nil }

        if requested != .microphone {
            // Both mode can carry on with the microphone; System mode can't.
            let fallback: InputSource? = requested == .both ? .microphone : nil
            switch permissions.screenRecording {
            case .granted:
                break
            case .notRequested:
                ask(.screenRecordingNotRequested, fallback: fallback, for: request)
                return nil
            case .denied:
                ask(.screenRecordingRefused, fallback: fallback, for: request)
                return nil
            }
        }

        return requested
    }

    private func ask(
        _ reason: RecordingPermissionRequest.Reason,
        fallback: InputSource?,
        for recordingRequest: RecordingRequest
    ) {
        let request = RecordingPermissionRequest(
            recordingRequestID: recordingRequest.id,
            reason: reason,
            fallback: fallback
        )
        recordingPhase = .requestingPermission(recordingRequest, request)
    }

    /// System audio failed to start for a source that needs it — don't record
    /// half of what was asked for; remember the denial and show the sheet.
    private func refuseSystemAudio(for request: RecordingRequest) {
        permissions.noteScreenRecordingAccess(.denied)
        let fallback: InputSource? = request.inputSource == .both ? .microphone : nil
        ask(.screenRecordingRefused, fallback: fallback, for: request)
        statusMessage = "Ready"
    }

    /// Answer a pending request by recording with what macOS does allow.
    ///
    /// The user's ``inputSource`` preference is deliberately left alone: this is
    /// a decision about one recording, not a new default.
    func recordWithReducedInput(requestID: UUID? = nil) async {
        guard
            case .requestingPermission(let recordingRequest, let permissionRequest) = recordingPhase,
            requestID == nil || requestID == permissionRequest.id,
            let fallback = permissionRequest.fallback
        else { return }
        _ = await beginRecording(recordingRequest, using: fallback)
    }

    /// Answer a pending request by going to fix the permission — the system
    /// prompt, or the System Settings pane. System Audio then moves on to
    /// the restart macOS insists on before the grant reaches Hover.
    func grantPermission(requestID: UUID? = nil) {
        guard
            case .requestingPermission(let recordingRequest, let permissionRequest) = recordingPhase,
            requestID == nil || requestID == permissionRequest.id
        else { return }
        switch permissionRequest.reason {
        case .screenRecordingNotRequested:
            permissions.requestScreenRecording()
            recordingPhase = .requestingPermission(
                recordingRequest,
                permissionRequest.awaitingRelaunch()
            )
        case .screenRecordingRefused:
            permissions.openSettings(for: .screenRecording)
            // Forget the cached denial so the next Record can probe again after
            // the user flips the switch in System Settings.
            permissions.noteScreenRecordingAccess(.notRequested)
            recordingPhase = .requestingPermission(
                recordingRequest,
                permissionRequest.awaitingRelaunch()
            )
        case .screenRecordingNeedsRelaunch:
            permissions.relaunch()
        case .microphoneRefused:
            // macOS offers its own "Quit & Reopen" when the switch is flipped,
            // so there's nothing left for Hover to walk the user through.
            permissions.openSettings(for: .microphone)
            recordingPhase = .idle
        }
    }

    func dismissPermissionRequest(requestID: UUID? = nil) {
        guard case .requestingPermission(_, let permissionRequest) = recordingPhase,
            requestID == nil || requestID == permissionRequest.id
        else { return }
        recordingPhase = .idle
    }

    private func beginRecording(_ request: RecordingRequest, using source: InputSource) async
        -> Bool
    {
        guard requestIsCurrent(request.id) else { return false }
        if case .failure(let failure) = capabilities {
            failRecording(requestID: request.id, failure: failure)
            return false
        }

        committedChunks = []
        lastResult = nil
        presentedFailureMessage = nil
        chunksTranscribed = 0

        let destination = transcriptStore.availableRecordingDestination(
            for: Date(),
            in: request.outputDirectory
        )
        let title = destination.title
        let logURL = destination.url
        let state = RecordingSessionState(
            id: request.id,
            title: title,
            requestedInputSource: request.inputSource,
            activeInputSource: source,
            outputURL: logURL
        )
        recordingPhase = .starting(state)
        // The file is written lazily on the first committed chunk (see persistTranscript),
        // so a recording that captures no speech never leaves an empty transcript behind.
        log("Saving to: \(logURL.path)")
        log("Input source: \(source.label)")

        let session = RecordingSession(
            state: state,
            configuration: .init(
                outputPath: logURL,
                sampleRate: configuration.sampleRate
            ),
            transcriber: transcriber,
            audioCapture: audioCapture,
            transcriptStore: transcriptStore,
            onUpdate: { [weak self] update in
                self?.applySessionUpdate(update, sessionID: state.id)
            }
        )
        currentSession = session

        do {
            let outcome = try await session.start()
            guard requestIsCurrent(state.id) else {
                await session.cancel()
                return false
            }
            if source != .microphone && !outcome.systemStarted {
                await session.cancel()
                currentSession = nil
                refuseSystemAudio(for: request)
                return false
            }
            if outcome.systemStarted {
                permissions.noteScreenRecordingAccess(.granted)
            }
            recordingPhase = .recording(state)
            statusMessage = "Recording..."

            if pendingStopRequestID == state.id {
                let saved = await finalize(session: session, state: state)
                resolvePendingStops(for: state.id, with: saved)
            }
            return true
        } catch {
            log("ERROR: \(error.localizedDescription)")
            if source != .microphone {
                let session = currentSession
                currentSession = nil
                if let session { await session.cancel() }
                refuseSystemAudio(for: request)
                return false
            }
            failRecording(
                requestID: request.id,
                failure: RecordingFailure(
                    kind: .captureStart,
                    message: "Failed to start: \(error.localizedDescription)"
                )
            )
            return false
        }
    }

    @discardableResult
    func stopRecording() async -> RecordingResult? {
        switch recordingPhase {
        case .checkingReadiness(let request):
            return await waitForPendingStop(requestID: request.id)
        case .requestingPermission:
            recordingPhase = .idle
            return lastResult
        case .starting(let state):
            return await waitForPendingStop(requestID: state.id)
        case .recording(let state):
            guard let session = currentSession else { return lastResult }
            return await finalize(session: session, state: state)
        case .stopping, .processing:
            return await finalizationTask?.value ?? lastResult
        case .cancelling:
            return lastResult
        case .idle, .completed, .failed:
            return lastResult
        }
    }

    private func finalize(
        session: RecordingSession,
        state: RecordingSessionState
    ) async -> RecordingResult? {
        if let finalizationTask { return await finalizationTask.value }

        recordingPhase = .stopping(state)
        statusMessage = "Transcribing…"
        let task = Task { @MainActor [weak self] in
            let result = await session.stop()
            guard !Task.isCancelled,
                let self,
                self.requestIsCurrent(state.id)
            else { return self?.lastResult }
            self.currentSession = nil
            if let warning = result.warnings.last { self.presentedFailureMessage = warning.message }
            return self.finishRecording(result)
        }
        finalizationTask = task
        let saved = await task.value
        finalizationTask = nil
        return saved
    }

    /// Reloads the transcript list and runs post-recording side effects.
    private func finishRecording(_ result: RecordingResult) -> RecordingResult {
        statusMessage = "Ready"
        lastResult = result
        if !result.body.isEmpty { committedChunks = [result.body] }
        if let failure = result.failure {
            presentedFailureMessage = failure.message
            recordingPhase = .failed(failure)
        } else {
            recordingPhase = .completed(result)
        }
        return result
    }

    func cancelRecording() async {
        guard let session = currentSession else {
            if case .requestingPermission = recordingPhase { recordingPhase = .idle }
            return
        }
        let state = session.state
        recordingPhase = .cancelling(state)
        finalizationTask?.cancel()
        await session.cancel()
        currentSession = nil
        finalizationTask = nil
        statusMessage = "Ready"
        recordingPhase = .idle
        resolvePendingStops(for: state.id, with: lastResult)
    }

    private func requestIsCurrent(_ id: UUID) -> Bool {
        switch recordingPhase {
        case .checkingReadiness(let request), .requestingPermission(let request, _):
            return request.id == id
        case .starting(let state), .recording(let state), .stopping(let state),
            .processing(let state, _), .cancelling(let state):
            return state.id == id
        case .idle, .completed, .failed:
            return false
        }
    }

    private func waitForPendingStop(requestID: UUID) async -> RecordingResult? {
        pendingStopRequestID = requestID
        return await withCheckedContinuation { continuation in
            pendingStopWaiters[requestID, default: []].append(continuation)
        }
    }

    private func resolvePendingStops(for requestID: UUID, with result: RecordingResult?) {
        if pendingStopRequestID == requestID { pendingStopRequestID = nil }
        let waiters = pendingStopWaiters.removeValue(forKey: requestID) ?? []
        for waiter in waiters { waiter.resume(returning: result) }
    }

    private func failRecording(requestID: UUID, failure: RecordingFailure) {
        guard requestIsCurrent(requestID) else { return }
        currentSession = nil
        statusMessage = "Ready"
        presentedFailureMessage = failure.message
        recordingPhase = .failed(failure)
        resolvePendingStops(for: requestID, with: lastResult)
    }

    /// Builds the "Recording — sys ✓ · mic ✓ · chunks: N · transcribing…" line
    /// from the capture's status plus the engine's own chunk count. Runs on the
    /// main queue (the capture delivers status there).
    private func applyStatus(_ status: CaptureStatus) {
        guard isRecording else { return }
        var parts: [String] = []
        // Reads the source in use, not the preference: a recording the user
        // agreed to run mic-only shouldn't sit at "sys: waiting" forever.
        if activeInputSource != .microphone {
            parts.append(status.systemActive ? "sys ✓" : "sys: waiting")
        }
        if activeInputSource != .system {
            parts.append(status.micActive ? "mic ✓" : "mic: waiting")
        }
        parts.append("chunks: \(chunksTranscribed)")
        if status.transcribing { parts.append("transcribing…") }
        statusMessage = "Recording — \(parts.joined(separator: " · "))"
    }

    private func applySessionUpdate(_ update: RecordingSessionUpdate, sessionID: UUID) {
        guard requestIsCurrent(sessionID) else { return }
        switch update {
        case .committed(let text, let chunkCount):
            chunksTranscribed = chunkCount
            // Session sends the full body so far (plain or track-labeled Markdown).
            committedChunks = text.isEmpty ? [] : [text]
        case .status(let status, let chunkCount):
            chunksTranscribed = chunkCount
            applyStatus(status)
        case .warning(let message):
            presentedFailureMessage = message
        }
    }
}
