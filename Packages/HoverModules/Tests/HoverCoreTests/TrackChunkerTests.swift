import Testing

@testable import HoverCore

/// Both mode's turn taking, exercised the way the real capture drives it: samples
/// arrive per pipe with the time they were received, and one chunk at a time goes
/// to the shared Transcriber.
@Suite struct TrackChunkerTests {

    private let sampleRate = 16_000

    private func makeChunker(sources: [AudioSource] = [.microphone, .system]) -> TrackChunker {
        TrackChunker(
            sources: sources,
            configuration: RecordingConfiguration(
                sampleRate: 16_000,
                maxChunkSeconds: 10,
                minChunkSeconds: 3,
                silenceWindowSeconds: 0.7,
                silenceRMSThreshold: 0.004
            )
        )
    }

    private func loud(seconds: Double) -> [Float] {
        Array(repeating: 0.5, count: Int(seconds * 16_000))
    }

    /// Stream `seconds` of continuous audio for one pipe in one-second buffers,
    /// starting at `from` on the session clock.
    private func stream(
        _ chunker: inout TrackChunker,
        _ source: AudioSource,
        from: Double,
        seconds: Int
    ) {
        for second in 0..<seconds {
            chunker.append(loud(seconds: 1), from: source, endingAt: from + Double(second) + 1)
        }
    }

    @Test func onlyTheRunningSourceProducesChunks() {
        var chunker = makeChunker(sources: [.system])
        stream(&chunker, .microphone, from: 0, seconds: 12)
        stream(&chunker, .system, from: 0, seconds: 12)

        let chunk = chunker.nextChunk(force: false)
        #expect(chunk?.source == .system)
    }

    @Test func nothingFlushesBelowTheMinimum() {
        var chunker = makeChunker()
        stream(&chunker, .microphone, from: 0, seconds: 1)
        #expect(chunker.nextChunk(force: false) == nil)
    }

    @Test func tracksTakeTurnsWhileBothAreTalking() {
        var chunker = makeChunker()
        stream(&chunker, .microphone, from: 0, seconds: 30)
        stream(&chunker, .system, from: 0, seconds: 30)

        var order: [AudioSource] = []
        while let chunk = chunker.nextChunk(force: false) { order.append(chunk.source) }

        #expect(order.filter { $0 == .microphone }.count == 3)
        #expect(order.filter { $0 == .system }.count == 3)
        #expect(order == [.microphone, .system, .microphone, .system, .microphone, .system])
    }

    /// The regression: system audio delivers nothing while nothing is playing, so
    /// it has far fewer samples than the mic by the time something starts playing.
    /// Turn taking must not read that as "system is a minute behind and owes us a
    /// minute of audio", which stops the mic being transcribed at all from there on.
    @Test func aPipeThatStartsLateDoesNotTakeOverTheTranscriber() {
        var chunker = makeChunker()
        var chunks: [AudioChunk] = []

        // A minute of Both-mode recording: each running pipe delivers a second of
        // audio per second, system audio only starts playing 30s in, and the one
        // shared Transcriber takes a chunk every other second.
        for second in 1...60 {
            chunker.append(loud(seconds: 1), from: .microphone, endingAt: Double(second))
            if second > 30 {
                chunker.append(loud(seconds: 1), from: .system, endingAt: Double(second))
            }
            if second.isMultiple(of: 2), let chunk = chunker.nextChunk(force: false) {
                chunks.append(chunk)
            }
        }

        #expect(chunks.contains { $0.source == .system })
        // The mic keeps its turn after system audio joins.
        #expect(chunks.contains { $0.source == .microphone && $0.startTime >= 40 })
    }

    @Test func chunksAreStampedWithTheTimeTheAudioArrived() {
        var chunker = makeChunker()
        stream(&chunker, .microphone, from: 0, seconds: 10)
        // System audio only starts a minute in.
        stream(&chunker, .system, from: 60, seconds: 10)

        let mic = chunker.nextChunk(force: false)
        let system = chunker.nextChunk(force: false)

        #expect(mic?.source == .microphone)
        #expect(abs((mic?.startTime ?? -1) - 0) < 0.001)
        #expect(abs((mic?.endTime ?? -1) - 10) < 0.001)
        // Ordering the two tracks by these timestamps has to put system second,
        // however little audio it has delivered.
        #expect(system?.source == .system)
        #expect(abs((system?.startTime ?? -1) - 60) < 0.001)
        #expect(abs((system?.endTime ?? -1) - 70) < 0.001)
    }

    @Test func forceDrainsEveryTrack() {
        var chunker = makeChunker()
        stream(&chunker, .microphone, from: 0, seconds: 2)
        stream(&chunker, .system, from: 0, seconds: 2)

        var sources: Set<AudioSource> = []
        while let chunk = chunker.nextChunk(force: true) { sources.insert(chunk.source) }

        #expect(sources == [.microphone, .system])
    }
}
