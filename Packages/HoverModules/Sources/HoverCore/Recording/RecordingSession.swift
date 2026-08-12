import Foundation

public struct RecordingRequest: Sendable, Equatable {
    public let id: UUID
    public let inputSource: InputSource
    public let tagsSpeakers: Bool
    public let outputDirectory: URL

    public init(
        id: UUID = UUID(),
        inputSource: InputSource,
        tagsSpeakers: Bool,
        outputDirectory: URL
    ) {
        self.id = id
        self.inputSource = inputSource
        self.tagsSpeakers = tagsSpeakers
        self.outputDirectory = outputDirectory
    }
}

public struct RecordingSessionState: Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let requestedInputSource: InputSource
    public let activeInputSource: InputSource
    public let tagsSpeakers: Bool
    public let outputURL: URL

    public var inputSource: InputSource { activeInputSource }

    public init(
        id: UUID,
        title: String,
        requestedInputSource: InputSource,
        activeInputSource: InputSource,
        tagsSpeakers: Bool,
        outputURL: URL
    ) {
        self.id = id
        self.title = title
        self.requestedInputSource = requestedInputSource
        self.activeInputSource = activeInputSource
        self.tagsSpeakers = tagsSpeakers
        self.outputURL = outputURL
    }
}

public enum RecordingProcessingStage: Sendable, Equatable {
    case flushingFinalChunk
    case transcribing
    case taggingSpeakers
    case saving
}

public struct RecordingWarning: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case unavailableSystemAudio
        case lostTranscriptChunk
        case speakerTagging
        case persistence
    }

    public let kind: Kind
    public let message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

public struct RecordingFailure: Error, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case notReady
        case unavailableTranscriber
        case captureStart
        case persistence
        case cancelled
    }

    public let kind: Kind
    public let message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

public struct RecordingCapabilities: Sendable, Equatable {
    public let speakerTaggingAvailable: Bool

    public init(speakerTaggingAvailable: Bool) {
        self.speakerTaggingAvailable = speakerTaggingAvailable
    }
}

public enum ApplicationReadiness: Sendable, Equatable {
    case checking
    case settingUpModels(ModelSetupStatus)
    case ready(RecordingCapabilities)
    case unavailable(RecordingFailure)
}

public enum RecordingPhase: Sendable, Equatable {
    case idle
    case checkingReadiness(RecordingRequest)
    case requestingPermission(RecordingRequest, RecordingPermissionRequest)
    case starting(RecordingSessionState)
    case recording(RecordingSessionState)
    case stopping(RecordingSessionState)
    case processing(RecordingSessionState, RecordingProcessingStage)
    case completed(RecordingResult)
    case cancelling(RecordingSessionState)
    case failed(RecordingFailure)
}

public struct RecordingResult: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case saved(URL)
        case noSpeech
    }

    public let session: RecordingSessionState
    public let path: URL?
    public let body: String
    public let warnings: [RecordingWarning]
    public let failure: RecordingFailure?

    public init(
        session: RecordingSessionState,
        path: URL?,
        body: String,
        warnings: [RecordingWarning],
        failure: RecordingFailure? = nil
    ) {
        self.session = session
        self.path = path
        self.body = body
        self.warnings = warnings
        self.failure = failure
    }

    public var outcome: Outcome {
        if let path { return .saved(path) }
        return .noSpeech
    }
}

public enum RecordingSessionUpdate: Sendable {
    case committed(text: String, chunkCount: Int)
    case status(CaptureStatus, chunkCount: Int)
    case processing
    case warning(String)
}

/// Single owner of one recording's ordered audio, transcription, optional
/// speaker pass, persistence, final draining, and cancellation.
public actor RecordingSession {
    public nonisolated let state: RecordingSessionState

    private let configuration: Configuration
    private let transcriber: any Transcriber
    private let audioCapture: any AudioCapture
    private let transcriptStore: any TranscriptStore
    private let speakerDiarizer: any SpeakerDiarizer
    private let onUpdate: @MainActor @Sendable (RecordingSessionUpdate) -> Void

    private var consumerTask: Task<Void, Never>?
    private var stopTask: Task<RecordingResult, Never>?
    private var chunks: [String] = []
    private var segments: [TextSegment] = []
    private var warnings: [RecordingWarning] = []
    private var persistenceFailure: RecordingFailure?
    private var cancelled = false

    public struct Configuration: Sendable {
        public let outputPath: URL
        public let sampleRate: Int
        public let retainFullRecording: Bool

        public init(outputPath: URL, sampleRate: Int, retainFullRecording: Bool) {
            self.outputPath = outputPath
            self.sampleRate = sampleRate
            self.retainFullRecording = retainFullRecording
        }
    }

    public init(
        state: RecordingSessionState,
        configuration: Configuration,
        transcriber: any Transcriber,
        audioCapture: any AudioCapture,
        transcriptStore: any TranscriptStore,
        speakerDiarizer: any SpeakerDiarizer,
        onUpdate: @escaping @MainActor @Sendable (RecordingSessionUpdate) -> Void
    ) {
        self.state = state
        self.configuration = configuration
        self.transcriber = transcriber
        self.audioCapture = audioCapture
        self.transcriptStore = transcriptStore
        self.speakerDiarizer = speakerDiarizer
        self.onUpdate = onUpdate
    }

    public func start() async throws -> CaptureOutcome {
        let start = try await audioCapture.start(
            inputSource: state.inputSource,
            retainFullRecording: configuration.retainFullRecording
        )
        consumerTask = Task { [events = start.events] in
            for await event in events {
                if Task.isCancelled { break }
                await self.consume(event)
            }
        }
        return start.outcome
    }

    public func stop() async -> RecordingResult {
        if let stopTask { return await stopTask.value }
        let task = Task { await self.finalize() }
        stopTask = task
        return await task.value
    }

    public func cancel() async {
        cancelled = true
        stopTask?.cancel()
        consumerTask?.cancel()
        _ = await audioCapture.stop()
        await consumerTask?.value
        transcriptStore.discardDraft(at: configuration.outputPath)
    }

    public func noteWarning(_ warning: RecordingWarning) {
        warnings.append(warning)
    }

    private func consume(_ event: AudioCaptureEvent) async {
        guard !cancelled else { return }
        switch event {
        case .status(let status):
            await onUpdate(.status(status, chunkCount: chunks.count))
        case .chunk(let chunk):
            do {
                let text = try await transcriber.transcribe(samples: chunk.samples)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cancelled else { return }
                if !text.isEmpty {
                    if chunks.last != text { chunks.append(text) }
                    if configuration.retainFullRecording {
                        segments.append(
                            TextSegment(
                                start: chunk.startTime,
                                end: chunk.endTime,
                                text: text
                            ))
                    }
                    do {
                        try persist(body: chunks.joined(separator: " "))
                        await onUpdate(.committed(text: text, chunkCount: chunks.count))
                    } catch {
                        await notePersistenceFailure(error)
                    }
                }
            } catch is CancellationError {
                break
            } catch {
                let warning = RecordingWarning(
                    kind: .lostTranscriptChunk,
                    message: "A transcript chunk was lost: \(error.localizedDescription)"
                )
                warnings.append(warning)
                await onUpdate(.warning(warning.message))
            }
            await audioCapture.noteTranscriptionFinished()
        }
    }

    private func finalize() async -> RecordingResult {
        let stopResult = await audioCapture.stop()
        await consumerTask?.value

        guard !cancelled else {
            return RecordingResult(
                session: state,
                path: nil,
                body: "",
                warnings: warnings
            )
        }

        var body = chunks.joined(separator: " ")
        if configuration.retainFullRecording,
            let samples = stopResult.fullRecording,
            !samples.isEmpty,
            !segments.isEmpty
        {
            await onUpdate(.processing)
            do {
                let turns = try await speakerDiarizer.diarize(
                    samples: samples,
                    sampleRate: configuration.sampleRate
                )
                guard !cancelled else {
                    transcriptStore.discardDraft(at: configuration.outputPath)
                    return RecordingResult(
                        session: state,
                        path: nil,
                        body: "",
                        warnings: warnings
                    )
                }
                let attributed = SpeakerAttribution.merge(segments: segments, turns: turns)
                if attributed.rangeOfCharacter(from: .alphanumerics) != nil {
                    body = attributed
                    do {
                        try persist(body: body)
                    } catch {
                        await notePersistenceFailure(error)
                    }
                }
            } catch is CancellationError {
                warnings.append(
                    RecordingWarning(
                        kind: .speakerTagging,
                        message: "Speaker tagging was cancelled."
                    ))
            } catch {
                let warning = RecordingWarning(
                    kind: .speakerTagging,
                    message:
                        "The transcript was saved without speaker labels. \(error.localizedDescription)"
                )
                warnings.append(warning)
                await onUpdate(.warning(warning.message))
            }
        }

        return RecordingResult(
            session: state,
            path: body.isEmpty || persistenceFailure != nil ? nil : configuration.outputPath,
            body: body,
            warnings: warnings,
            failure: persistenceFailure
        )
    }

    private func persist(body: String) throws {
        guard !cancelled else { return }
        if let persistenceFailure { throw persistenceFailure }
        try transcriptStore.write(
            title: state.title,
            body: body,
            to: configuration.outputPath
        )
    }

    private func notePersistenceFailure(_ error: Error) async {
        guard persistenceFailure == nil else { return }
        let failure = RecordingFailure(
            kind: .persistence,
            message: error.localizedDescription
        )
        persistenceFailure = failure
        warnings.append(RecordingWarning(kind: .persistence, message: failure.message))
        await onUpdate(.warning(failure.message))
    }
}
