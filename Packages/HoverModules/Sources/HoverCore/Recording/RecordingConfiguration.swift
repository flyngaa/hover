import Foundation

/// Stable audio and chunking policy shared by capture, transcription, and a
/// single recording session. Keeping it independent from presentation models
/// prevents platform adapters from depending on application state.
public struct RecordingConfiguration: Sendable, Equatable {
    public static let `default` = RecordingConfiguration()

    public let sampleRate: Int
    public let maxChunkSeconds: Double
    public let minChunkSeconds: Double
    public let silenceWindowSeconds: Double
    public let silenceRMSThreshold: Float

    public init(
        sampleRate: Int = 16_000,
        maxChunkSeconds: Double = 10,
        minChunkSeconds: Double = 3,
        silenceWindowSeconds: Double = 0.7,
        silenceRMSThreshold: Float = 0.004
    ) {
        self.sampleRate = sampleRate
        self.maxChunkSeconds = maxChunkSeconds
        self.minChunkSeconds = minChunkSeconds
        self.silenceWindowSeconds = silenceWindowSeconds
        self.silenceRMSThreshold = silenceRMSThreshold
    }
}
