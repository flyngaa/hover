import Foundation

/// A slice of captured audio ready to be transcribed, positioned on the
/// recording timeline (seconds).
public struct AudioChunk: Sendable {
    public let samples: [Float]
    public let startTime: Double
    public let endTime: Double

    public init(samples: [Float], startTime: Double, endTime: Double) {
        self.samples = samples
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// Decides when accumulated audio should be cut into a ``AudioChunk``.
///
/// Pure logic — feed it samples, ask it for the next chunk. No audio hardware,
/// no queues, no timers, so the chunking policy (min/max length, trailing
/// silence, timeline accounting) can be unit-tested directly.
public struct Chunker {
    public let sampleRate: Int
    public let maxChunkSeconds: Double
    public let minChunkSeconds: Double
    public let silenceWindowSeconds: Double
    public let silenceRMSThreshold: Float

    private var pending: [Float] = []
    /// Total samples cut into chunks so far — used to time-stamp each chunk.
    public private(set) var flushedSampleCount = 0

    public init(
        sampleRate: Int = RecordingConfiguration.default.sampleRate,
        maxChunkSeconds: Double = RecordingConfiguration.default.maxChunkSeconds,
        minChunkSeconds: Double = RecordingConfiguration.default.minChunkSeconds,
        silenceWindowSeconds: Double = RecordingConfiguration.default.silenceWindowSeconds,
        silenceRMSThreshold: Float = RecordingConfiguration.default.silenceRMSThreshold
    ) {
        self.sampleRate = sampleRate
        self.maxChunkSeconds = maxChunkSeconds
        self.minChunkSeconds = minChunkSeconds
        self.silenceWindowSeconds = silenceWindowSeconds
        self.silenceRMSThreshold = silenceRMSThreshold
    }

    public var isEmpty: Bool { pending.isEmpty }

    /// Add freshly captured samples to the buffer.
    public mutating func append(_ samples: [Float]) {
        pending.append(contentsOf: samples)
    }

    /// Return the next chunk if the buffer is ready to flush, else `nil`.
    ///
    /// - Parameters:
    ///   - force: flush whatever remains regardless of size/silence (used at stop).
    ///   - transcriptionInFlight: when true, hold off so chunks don't pile up
    ///     while a previous chunk is still being transcribed.
    public mutating func nextChunk(force: Bool, transcriptionInFlight: Bool) -> AudioChunk? {
        guard shouldFlush(force: force, transcriptionInFlight: transcriptionInFlight) else {
            return nil
        }

        let samples = pending
        pending = []

        // Each chunk occupies a contiguous slice of the session timeline, so its
        // start/end (seconds) come straight from the running count.
        let startTime = Double(flushedSampleCount) / Double(sampleRate)
        flushedSampleCount += samples.count
        let endTime = Double(flushedSampleCount) / Double(sampleRate)
        return AudioChunk(samples: samples, startTime: startTime, endTime: endTime)
    }

    /// Whether the buffered audio should be cut into a chunk now.
    public func shouldFlush(force: Bool, transcriptionInFlight: Bool) -> Bool {
        if force { return !pending.isEmpty }
        guard !transcriptionInFlight else { return false }

        let seconds = Double(pending.count) / Double(sampleRate)
        if seconds >= maxChunkSeconds { return true }
        guard seconds >= minChunkSeconds else { return false }

        // Flush early if the tail has gone quiet — a natural sentence break.
        let windowCount = Int(silenceWindowSeconds * Double(sampleRate))
        let tail = pending.suffix(windowCount)
        return AudioLevel.rms(of: tail) < silenceRMSThreshold
    }
}
