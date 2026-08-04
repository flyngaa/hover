import Foundation

/// A live snapshot of what the capture is doing, for the status line.
struct CaptureStatus {
    let systemActive: Bool
    let micActive: Bool
    let transcribing: Bool
}

/// What actually started when capture began. Lets the engine decide user-facing
/// messaging (e.g. "recording mic only" when system audio couldn't start).
struct CaptureOutcome {
    let systemStarted: Bool
    /// Why system audio didn't start, when the recording carried on without it.
    let systemAudioFailure: String?

    init(systemStarted: Bool, systemAudioFailure: String? = nil) {
        self.systemStarted = systemStarted
        self.systemAudioFailure = systemAudioFailure
    }
}

/// Captures audio and emits ready-to-transcribe chunks.
///
/// The seam between the OS audio plumbing and the rest of the app: production
/// uses ``LiveAudioCapture`` (ScreenCaptureKit + AVAudioEngine); a test can
/// supply a fake that feeds canned samples through the same callbacks.
protocol AudioCapture: AnyObject {
    /// Called (on an internal queue) with each chunk ready for transcription.
    var onChunk: ((AudioChunk) -> Void)? { get set }
    /// Called periodically (on the main queue) with the current capture status.
    var onStatus: ((CaptureStatus) -> Void)? { get set }

    /// Begin capturing from the given source(s).
    ///
    /// - Parameter retainFullRecording: keep the entire recording in memory so
    ///   it can be fetched from ``stop()`` (used for speaker tagging).
    /// - Returns: which sources actually started.
    func start(inputSource: InputSource, retainFullRecording: Bool) async throws -> CaptureOutcome

    /// Stop capturing, flush the final chunk, and return the full recording if
    /// it was retained (else `nil`).
    func stop() -> [Float]?

    /// Tell the capture that a transcription just finished, so it can resume
    /// flushing new chunks.
    func noteTranscriptionFinished()
}
