import Foundation

/// A live snapshot of what capture is doing, for presentation only.
public struct CaptureStatus: Sendable {
    public let systemActive: Bool
    public let micActive: Bool
    public let transcribing: Bool

    public init(systemActive: Bool, micActive: Bool, transcribing: Bool) {
        self.systemActive = systemActive
        self.micActive = micActive
        self.transcribing = transcribing
    }
}

/// What actually started when capture began.
public struct CaptureOutcome: Sendable {
    public let systemStarted: Bool
    public let systemAudioFailure: String?

    public init(systemStarted: Bool, systemAudioFailure: String? = nil) {
        self.systemStarted = systemStarted
        self.systemAudioFailure = systemAudioFailure
    }
}

public enum AudioCaptureEvent: Sendable {
    case chunk(AudioChunk)
    case status(CaptureStatus)
}

public struct AudioCaptureStart: Sendable {
    public let outcome: CaptureOutcome
    public let events: AsyncStream<AudioCaptureEvent>

    public init(outcome: CaptureOutcome, events: AsyncStream<AudioCaptureEvent>) {
        self.outcome = outcome
        self.events = events
    }
}

/// Ordered async boundary between Apple audio callbacks and a recording
/// session. `stop()` finishes the stream only after yielding the final chunk.
public protocol AudioCapture: Sendable {
    func start(inputSource: InputSource) async throws -> AudioCaptureStart
    func stop() async
    func noteTranscriptionFinished() async
}
