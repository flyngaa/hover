import Testing

@testable import HoverCore

/// The chunking policy is pure value logic, so it can be exercised directly with
/// canned sample buffers — no audio hardware, queues, or timers involved.
@Suite struct ChunkerTests {

    // 16 kHz mono, matching the app's Config, spelled out so the test is self-contained.
    private func makeChunker() -> Chunker {
        Chunker(
            sampleRate: 16_000,
            maxChunkSeconds: 10,
            minChunkSeconds: 3,
            silenceWindowSeconds: 0.7,
            silenceRMSThreshold: 0.004
        )
    }

    private func loud(seconds: Double) -> [Float] {
        Array(repeating: 0.5, count: Int(seconds * 16_000))
    }

    private func silent(seconds: Double) -> [Float] {
        Array(repeating: 0.0, count: Int(seconds * 16_000))
    }

    @Test func emptyBufferNeverFlushes() {
        var chunker = makeChunker()
        #expect(chunker.isEmpty)
        #expect(chunker.nextChunk(force: false, transcriptionInFlight: false) == nil)
        // Even a forced flush yields nothing when there's nothing buffered.
        #expect(chunker.nextChunk(force: true, transcriptionInFlight: false) == nil)
    }

    @Test func belowMinimumHolds() {
        var chunker = makeChunker()
        chunker.append(loud(seconds: 1))  // under the 3s minimum
        #expect(chunker.shouldFlush(force: false, transcriptionInFlight: false) == false)
        #expect(chunker.nextChunk(force: false, transcriptionInFlight: false) == nil)
    }

    @Test func forceFlushesRemainder() {
        var chunker = makeChunker()
        chunker.append(loud(seconds: 1))
        let chunk = chunker.nextChunk(force: true, transcriptionInFlight: false)
        #expect(chunk != nil)
        #expect(chunk?.samples.count == 16_000)
        #expect(abs((chunk?.startTime ?? -1) - 0) < 0.0001)
        #expect(abs((chunk?.endTime ?? -1) - 1) < 0.0001)
        #expect(chunker.isEmpty)
    }

    @Test func maxLengthForcesFlush() {
        var chunker = makeChunker()
        chunker.append(loud(seconds: 10))  // hits the hard cap
        #expect(chunker.shouldFlush(force: false, transcriptionInFlight: false))
        let chunk = chunker.nextChunk(force: false, transcriptionInFlight: false)
        #expect(chunk?.samples.count == 160_000)
        #expect(abs((chunk?.endTime ?? -1) - 10) < 0.0001)
    }

    @Test func trailingSilenceFlushesEarly() {
        var chunker = makeChunker()
        // 4s total, past the 3s minimum, with the last 0.7s gone quiet.
        chunker.append(loud(seconds: 3.3))
        chunker.append(silent(seconds: 0.7))
        #expect(chunker.shouldFlush(force: false, transcriptionInFlight: false))
        #expect(chunker.nextChunk(force: false, transcriptionInFlight: false) != nil)
    }

    @Test func transcriptionInFlightHoldsUnlessForced() {
        var chunker = makeChunker()
        chunker.append(loud(seconds: 11))  // way past the cap
        // Held back so chunks don't pile up while a previous one is transcribing.
        #expect(chunker.shouldFlush(force: false, transcriptionInFlight: true) == false)
        // Stop still forces the final chunk out.
        #expect(chunker.shouldFlush(force: true, transcriptionInFlight: true))
    }

    @Test func timelineAccountingIsContiguous() {
        var chunker = makeChunker()
        chunker.append(loud(seconds: 10))
        let first = chunker.nextChunk(force: false, transcriptionInFlight: false)
        chunker.append(loud(seconds: 5))
        let second = chunker.nextChunk(force: true, transcriptionInFlight: false)

        #expect(abs((first?.startTime ?? -1) - 0) < 0.0001)
        #expect(abs((first?.endTime ?? -1) - 10) < 0.0001)
        // The next chunk picks up exactly where the last one ended.
        #expect(abs((second?.startTime ?? -1) - (first?.endTime ?? -2)) < 0.0001)
        #expect(abs((second?.endTime ?? -1) - 15) < 0.0001)
        #expect(chunker.flushedSampleCount == 240_000)
    }

}

/// Loudness measurement, shared by the chunker's quiet-tail rule and the
/// transcriber's "don't bother running whisper" check.
@Suite struct AudioLevelTests {

    @Test func rms() {
        #expect(abs(AudioLevel.rms(of: [0.6, -0.8]) - 0.7071) < 0.0001)
        #expect(AudioLevel.rms(of: [Float]()) == 0)
    }
}
