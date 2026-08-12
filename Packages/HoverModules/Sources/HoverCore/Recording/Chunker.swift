import Foundation

/// A slice of captured audio ready to be transcribed, positioned on the
/// recording timeline (seconds).
public struct AudioChunk: Sendable {
    public let samples: [Float]
    public let startTime: Double
    public let endTime: Double
    /// Which capture pipe produced these samples. Required for Both-mode track labels.
    public let source: AudioSource

    public init(
        samples: [Float],
        startTime: Double,
        endTime: Double,
        source: AudioSource = .microphone
    ) {
        self.samples = samples
        self.startTime = startTime
        self.endTime = endTime
        self.source = source
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
    public let source: AudioSource

    private var pending: [Float] = []
    /// Total samples cut into chunks so far.
    public private(set) var flushedSampleCount = 0
    /// When the oldest buffered sample arrived, in seconds since the recording
    /// started; `nil` while nothing is buffered. This is what decides whose turn
    /// it is when two tracks share one Transcriber.
    public private(set) var pendingStartTime: Double?
    /// When the newest buffered sample arrived, on the same clock.
    private var pendingEndTime: Double?

    public init(
        sampleRate: Int = RecordingConfiguration.default.sampleRate,
        maxChunkSeconds: Double = RecordingConfiguration.default.maxChunkSeconds,
        minChunkSeconds: Double = RecordingConfiguration.default.minChunkSeconds,
        silenceWindowSeconds: Double = RecordingConfiguration.default.silenceWindowSeconds,
        silenceRMSThreshold: Float = RecordingConfiguration.default.silenceRMSThreshold,
        source: AudioSource = .microphone
    ) {
        self.sampleRate = sampleRate
        self.maxChunkSeconds = maxChunkSeconds
        self.minChunkSeconds = minChunkSeconds
        self.silenceWindowSeconds = silenceWindowSeconds
        self.silenceRMSThreshold = silenceRMSThreshold
        self.source = source
    }

    public var isEmpty: Bool { pending.isEmpty }

    /// Add freshly captured samples to the buffer.
    ///
    /// - Parameter sessionTime: when the last of these samples arrived, in
    ///   seconds since the recording started. Both tracks stamp the same clock,
    ///   so their chunks can be ordered against each other and a pipe that goes
    ///   quiet for a while doesn't rewind its own timeline. Defaults to carrying
    ///   straight on from the samples already accounted for, which is what a
    ///   single uninterrupted source does anyway.
    public mutating func append(_ samples: [Float], endingAt sessionTime: Double? = nil) {
        guard !samples.isEmpty else { return }
        let duration = Double(samples.count) / Double(sampleRate)
        let end = sessionTime ?? contiguousTime + duration
        if pending.isEmpty {
            pendingStartTime = max(0, end - duration)
        }
        pendingEndTime = max(end, pendingEndTime ?? end)
        pending.append(contentsOf: samples)
    }

    /// The point on the timeline that samples arriving now would continue from.
    private var contiguousTime: Double {
        pendingEndTime ?? Double(flushedSampleCount) / Double(sampleRate)
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

        // Never hand over more than one chunk's worth at a time. A track that
        // waited while the other was being transcribed would otherwise arrive as
        // a single multi-minute chunk: slow to transcribe, and one shapeless
        // paragraph in the transcript.
        let count = min(pending.count, max(1, Int(maxChunkSeconds * Double(sampleRate))))
        let samples = Array(pending.prefix(count))
        pending.removeFirst(count)

        let startTime = pendingStartTime ?? Double(flushedSampleCount) / Double(sampleRate)
        let duration = Double(count) / Double(sampleRate)
        flushedSampleCount += count
        let endTime: Double
        if pending.isEmpty {
            // The last sample's arrival time, so a gap inside the chunk counts.
            endTime = max(pendingEndTime ?? startTime, startTime + duration)
            pendingStartTime = nil
            pendingEndTime = nil
        } else {
            // What's left of the buffer starts where this chunk ends.
            endTime = startTime + duration
            pendingStartTime = endTime
        }
        return AudioChunk(
            samples: samples,
            startTime: startTime,
            endTime: endTime,
            source: source
        )
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
