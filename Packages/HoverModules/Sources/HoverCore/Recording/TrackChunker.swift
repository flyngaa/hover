import Foundation

/// One ``Chunker`` per capture pipe, plus the rule for whose turn it is.
///
/// Both mode keeps Mic and System apart all the way to the Transcriber, but there
/// is only one Transcriber, so the tracks take turns: the chunk whose audio has
/// been waiting longest goes next. Turn taking reads the recording's own clock,
/// never how much audio a pipe has delivered — system audio produces nothing
/// while nothing is playing, and a pipe that had a quiet spell would otherwise
/// look permanently "behind" and hold the Transcriber to itself, leaving the
/// other track untranscribed for the rest of the recording.
///
/// Pure logic, like ``Chunker`` itself: feed it samples with the time they
/// arrived, ask it for the next chunk.
public struct TrackChunker {
    private var chunkers: [Chunker]

    /// - Parameter sources: the pipes actually running for this recording. A
    ///   single-source recording has one, Both mode has two.
    public init(
        sources: [AudioSource],
        configuration: RecordingConfiguration = .default
    ) {
        chunkers = sources.map { source in
            Chunker(
                sampleRate: configuration.sampleRate,
                maxChunkSeconds: configuration.maxChunkSeconds,
                minChunkSeconds: configuration.minChunkSeconds,
                silenceWindowSeconds: configuration.silenceWindowSeconds,
                silenceRMSThreshold: configuration.silenceRMSThreshold,
                source: source
            )
        }
    }

    /// Buffer samples for one pipe. `sessionTime` is when the last of them
    /// arrived, in seconds since the recording started.
    public mutating func append(
        _ samples: [Float],
        from source: AudioSource,
        endingAt sessionTime: Double? = nil
    ) {
        guard let index = chunkers.firstIndex(where: { $0.source == source }) else { return }
        chunkers[index].append(samples, endingAt: sessionTime)
    }

    /// The next chunk to transcribe, or `nil` while every track is still filling
    /// up. `force` drains whatever is buffered, one chunk per call (used at stop).
    public mutating func nextChunk(force: Bool) -> AudioChunk? {
        let ready = chunkers.indices.filter {
            chunkers[$0].shouldFlush(force: force, transcriptionInFlight: false)
        }
        guard
            let next = ready.min(by: { left, right in
                let leftWait = chunkers[left].pendingStartTime ?? .greatestFiniteMagnitude
                let rightWait = chunkers[right].pendingStartTime ?? .greatestFiniteMagnitude
                if leftWait != rightWait { return leftWait < rightWait }
                return chunkers[left].source.sortOrder < chunkers[right].source.sortOrder
            })
        else { return nil }
        return chunkers[next].nextChunk(force: force, transcriptionInFlight: false)
    }
}
