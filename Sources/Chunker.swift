import Foundation

/// A slice of captured audio ready to be transcribed, positioned on the
/// recording timeline (seconds).
struct AudioChunk {
    let samples: [Float]
    let startTime: Double
    let endTime: Double
}

/// Decides when accumulated audio should be cut into a ``AudioChunk``.
///
/// Pure logic — feed it samples, ask it for the next chunk. No audio hardware,
/// no queues, no timers, so the chunking policy (min/max length, trailing
/// silence, timeline accounting) can be unit-tested directly.
struct Chunker {
    let sampleRate: Int
    let maxChunkSeconds: Double
    let minChunkSeconds: Double
    let silenceWindowSeconds: Double
    let silenceRMSThreshold: Float

    private var pending: [Float] = []
    /// Total samples cut into chunks so far — used to time-stamp each chunk.
    private(set) var flushedSampleCount = 0

    init(
        sampleRate: Int = TranscriberEngine.Config.sampleRate,
        maxChunkSeconds: Double = TranscriberEngine.Config.maxChunkSeconds,
        minChunkSeconds: Double = TranscriberEngine.Config.minChunkSeconds,
        silenceWindowSeconds: Double = TranscriberEngine.Config.silenceWindowSeconds,
        silenceRMSThreshold: Float = TranscriberEngine.Config.silenceRMSThreshold
    ) {
        self.sampleRate = sampleRate
        self.maxChunkSeconds = maxChunkSeconds
        self.minChunkSeconds = minChunkSeconds
        self.silenceWindowSeconds = silenceWindowSeconds
        self.silenceRMSThreshold = silenceRMSThreshold
    }

    var isEmpty: Bool { pending.isEmpty }

    /// Add freshly captured samples to the buffer.
    mutating func append(_ samples: [Float]) {
        pending.append(contentsOf: samples)
    }

    /// Return the next chunk if the buffer is ready to flush, else `nil`.
    ///
    /// - Parameters:
    ///   - force: flush whatever remains regardless of size/silence (used at stop).
    ///   - transcriptionInFlight: when true, hold off so chunks don't pile up
    ///     while a previous chunk is still being transcribed.
    mutating func nextChunk(force: Bool, transcriptionInFlight: Bool) -> AudioChunk? {
        guard shouldFlush(force: force, transcriptionInFlight: transcriptionInFlight) else { return nil }

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
    func shouldFlush(force: Bool, transcriptionInFlight: Bool) -> Bool {
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
