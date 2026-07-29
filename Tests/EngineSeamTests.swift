import Testing
import Foundation
@testable import TranscriberKit

/// These tests are the reason the seams exist: the engine's orchestration is
/// verified with fakes on every side — no whisper-cli, no audio devices, no disk,
/// no real user defaults. (Fakes live in Fakes.swift.)
@Suite struct EngineSeamTests {

    private func makeEngine(
        transcriber: Transcriber,
        capture: FakeAudioCapture = FakeAudioCapture()
    ) -> TranscriberEngine {
        TranscriberEngine(
            transcriber: transcriber,
            audioCapture: capture,
            transcriptStore: FakeTranscriptStore(),
            vaultFinder: FakeVaultFinder(),
            settings: InMemorySettings()
        )
    }

    /// Wait until `committedChunks` reaches the expected value (or time out).
    private func waitForCommitted(_ engine: TranscriberEngine, equals expected: [String]) async -> [String] {
        for _ in 0..<200 { // ~4s max
            let current = await MainActor.run { engine.committedChunks }
            if current == expected { return current }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await MainActor.run { engine.committedChunks }
    }

    @Test func transcribeCommitsRealText() async {
        let engine = makeEngine(transcriber: FakeTranscriber(result: "hello world"))
        engine.transcribe(samples: [0.5, 0.5, 0.5])
        #expect(await waitForCommitted(engine, equals: ["hello world"]) == ["hello world"])
    }

    @Test func silenceIsNotCommitted() async {
        let engine = makeEngine(transcriber: FakeTranscriber(result: ""))
        engine.transcribe(samples: [0.5, 0.5, 0.5])
        // Give any (erroneous) commit a chance to run, then confirm nothing landed.
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(await MainActor.run { engine.committedChunks }.isEmpty)
    }

    @Test func chunkFromCaptureFlowsThroughToCommittedText() async {
        let capture = FakeAudioCapture()
        let engine = makeEngine(transcriber: FakeTranscriber(result: "from capture"), capture: capture)

        // A chunk emitted by the capture is transcribed on a background queue and
        // committed on the main queue — the full wired-up path.
        capture.emit(AudioChunk(samples: [0.5, 0.5], startTime: 0, endTime: 1))

        #expect(await waitForCommitted(engine, equals: ["from capture"]) == ["from capture"])
    }
}
