import Foundation

public struct RecordingRequest: Sendable, Equatable {
    public let id: UUID
    public let inputSource: InputSource
    public let outputDirectory: URL

    public init(
        id: UUID = UUID(),
        inputSource: InputSource,
        outputDirectory: URL
    ) {
        self.id = id
        self.inputSource = inputSource
        self.outputDirectory = outputDirectory
    }
}

public struct RecordingSessionState: Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let requestedInputSource: InputSource
    public let activeInputSource: InputSource
    public let outputURL: URL

    public var inputSource: InputSource { activeInputSource }

    public init(
        id: UUID,
        title: String,
        requestedInputSource: InputSource,
        activeInputSource: InputSource,
        outputURL: URL
    ) {
        self.id = id
        self.title = title
        self.requestedInputSource = requestedInputSource
        self.activeInputSource = activeInputSource
        self.outputURL = outputURL
    }
}

public enum RecordingProcessingStage: Sendable, Equatable {
    case flushingFinalChunk
    case transcribing
    case saving
}

public struct RecordingWarning: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case unavailableSystemAudio
        case lostTranscriptChunk
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
    public init() {}
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
    case warning(String)
}

/// Single owner of one recording's ordered audio, transcription, persistence,
/// final draining, and cancellation.
public actor RecordingSession {
    public nonisolated let state: RecordingSessionState

    private let configuration: Configuration
    private let transcriber: any Transcriber
    private let audioCapture: any AudioCapture
    private let transcriptStore: any TranscriptStore
    private let onUpdate: @MainActor @Sendable (RecordingSessionUpdate) -> Void

    private var consumerTask: Task<Void, Never>?
    private var stopTask: Task<RecordingResult, Never>?
    /// Plain transcript pieces for single-source recordings.
    private var chunks: [String] = []
    /// Timestamped, source-tagged pieces when Both mode labels Mic / System tracks.
    private var segments: [TextSegment] = []
    private var warnings: [RecordingWarning] = []
    private var persistenceFailure: RecordingFailure?
    private var cancelled = false

    private var labelsTracks: Bool { state.activeInputSource == .both }

    private var committedPieceCount: Int {
        labelsTracks ? segments.count : chunks.count
    }

    public struct Configuration: Sendable {
        public let outputPath: URL
        public let sampleRate: Int

        public init(outputPath: URL, sampleRate: Int) {
            self.outputPath = outputPath
            self.sampleRate = sampleRate
        }
    }

    public init(
        state: RecordingSessionState,
        configuration: Configuration,
        transcriber: any Transcriber,
        audioCapture: any AudioCapture,
        transcriptStore: any TranscriptStore,
        onUpdate: @escaping @MainActor @Sendable (RecordingSessionUpdate) -> Void
    ) {
        self.state = state
        self.configuration = configuration
        self.transcriber = transcriber
        self.audioCapture = audioCapture
        self.transcriptStore = transcriptStore
        self.onUpdate = onUpdate
    }

    public func start() async throws -> CaptureOutcome {
        let start = try await audioCapture.start(inputSource: state.inputSource)
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
        await audioCapture.stop()
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
            await onUpdate(.status(status, chunkCount: committedPieceCount))
        case .chunk(let chunk):
            do {
                let text = try await transcriber.transcribe(samples: chunk.samples)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cancelled else { return }
                if !text.isEmpty {
                    appendTranscript(text: text, from: chunk)
                    let body = currentBody()
                    do {
                        try persist(body: body)
                        await onUpdate(.committed(text: body, chunkCount: committedPieceCount))
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

    private func appendTranscript(text: String, from chunk: AudioChunk) {
        if labelsTracks {
            let last = segments.last
            let duplicate =
                last?.text == text
                && last?.source == chunk.source
                && last?.start == chunk.startTime
                && last?.end == chunk.endTime
            guard !duplicate else { return }
            segments.append(
                TextSegment(
                    start: chunk.startTime,
                    end: chunk.endTime,
                    text: text,
                    source: chunk.source
                )
            )
        } else if chunks.last != text {
            chunks.append(text)
        }
    }

    private func currentBody() -> String {
        if labelsTracks {
            return TrackAttribution.merge(segments: segments)
        }
        return chunks.joined(separator: " ")
    }

    private func finalize() async -> RecordingResult {
        await audioCapture.stop()
        await consumerTask?.value

        guard !cancelled else {
            return RecordingResult(
                session: state,
                path: nil,
                body: "",
                warnings: warnings
            )
        }

        let body = currentBody()
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
