import Foundation
import HoverCore
import HoverPlatform
import Testing

@testable import HoverApp

@Suite @MainActor struct EngineSeamTests {
    private struct FailingWriteTranscriptStore: TranscriptStore {
        private let base = FakeTranscriptStore()

        func availableRecordingDestination(
            for date: Date,
            in directory: URL
        ) -> (title: String, url: URL) {
            base.availableRecordingDestination(for: date, in: directory)
        }

        func load(in directory: URL) throws -> TranscriptLibrary { try base.load(in: directory) }
        func rename(_ transcript: SavedTranscript, to newName: String) throws -> SavedTranscript {
            try base.rename(transcript, to: newName)
        }
        func move(
            _ transcript: SavedTranscript,
            toGroup group: String?,
            in directory: URL
        ) throws -> SavedTranscript {
            try base.move(transcript, toGroup: group, in: directory)
        }
        func relocate(
            _ transcripts: [SavedTranscript],
            to directory: URL
        ) -> TranscriptRelocationReport {
            base.relocate(transcripts, to: directory)
        }
        func delete(_ transcript: SavedTranscript) throws { try base.delete(transcript) }
        func matches(_ transcript: SavedTranscript, query: String) -> Bool {
            base.matches(transcript, query: query)
        }
        func content(of transcript: SavedTranscript) throws -> String {
            try base.content(of: transcript)
        }
        func write(title: String, body: String, to url: URL) throws {
            throw TranscriptStoreError.writeFailed(diagnostic: "simulated")
        }
    }

    private func makeEngine(
        transcriber: Transcriber,
        capture: FakeAudioCapture,
        transcriptStore: any TranscriptStore = FakeTranscriptStore(),
        inputSource: InputSource = .microphone
    ) -> RecordingModel {
        RecordingModel(
            transcriber: transcriber,
            audioCapture: capture,
            transcriptStore: transcriptStore,
            settings: InMemorySettings(inputSource: inputSource),
            permissions: FakeRecordingPermissions()
        )
    }

    /// Returns different text per source sample marker so Both-mode track tests
    /// can assert Mic vs System labels without a real Whisper.
    private struct SourceMarkerTranscriber: Transcriber {
        var unavailableReason: String? { nil }
        func transcribe(samples: [Float]) async throws -> String {
            if samples.first == Float(0.25) { return "from system" }
            return "from mic"
        }
    }

    private func waitForCommitted(
        _ engine: RecordingModel,
        equals expected: [String]
    ) async -> [String] {
        for _ in 0..<200 {
            if engine.committedChunks == expected { return engine.committedChunks }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return engine.committedChunks
    }

    private func completedResult(_ engine: RecordingModel) -> RecordingResult? {
        guard case .completed(let result) = engine.recordingPhase else { return nil }
        return result
    }

    @Test func transcribeCommitsRealText() async {
        let capture = FakeAudioCapture()
        let engine = makeEngine(
            transcriber: FakeTranscriber(result: "hello world"),
            capture: capture
        )
        await engine.startRecording()
        await capture.emit(AudioChunk(samples: [0.5], startTime: 0, endTime: 1))
        #expect(await waitForCommitted(engine, equals: ["hello world"]) == ["hello world"])
    }

    @Test func silenceIsNotCommitted() async {
        let capture = FakeAudioCapture()
        let engine = makeEngine(transcriber: FakeTranscriber(result: ""), capture: capture)
        await engine.startRecording()
        await capture.emit(AudioChunk(samples: [0.5], startTime: 0, endTime: 1))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(engine.committedChunks.isEmpty)
    }

    @Test func stoppingDrainsTheFinalChunk() async {
        let final = AudioChunk(samples: [0.5], startTime: 0, endTime: 1)
        let capture = FakeAudioCapture(chunkOnStop: final)
        let engine = makeEngine(
            transcriber: FakeTranscriber(result: "from final chunk"),
            capture: capture
        )
        await engine.startRecording()

        _ = await engine.stopRecording()

        #expect(engine.committedChunks == ["from final chunk"])
        #expect(completedResult(engine)?.outcome != nil)
    }

    @Test func duplicateStopCallersFinalizeOnce() async {
        let final = AudioChunk(samples: [0.5], startTime: 0, endTime: 1)
        let capture = FakeAudioCapture(chunkOnStop: final)
        let engine = makeEngine(transcriber: FakeTranscriber(result: "hello"), capture: capture)
        await engine.startRecording()

        async let first = engine.stopRecording()
        async let second = engine.stopRecording()
        _ = await (first, second)

        #expect(engine.committedChunks == ["hello"])
        #expect(completedResult(engine)?.body == "hello")
    }

    @Test func overlappingStartsCreateOnlyOneSession() async {
        let capture = FakeAudioCapture()
        let engine = makeEngine(transcriber: FakeTranscriber(result: "hello"), capture: capture)

        async let first: Bool = engine.startRecording()
        async let second: Bool = engine.startRecording()
        _ = await (first, second)

        #expect(await capture.startCount == 1)
        #expect(engine.isRecording)
        _ = await engine.stopRecording()
    }

    @Test func stopDuringStartupWaitsForTheSameSession() async {
        let capture = FakeAudioCapture(suspendsStart: true)
        let engine = makeEngine(transcriber: FakeTranscriber(result: "hello"), capture: capture)

        async let starting: Bool = engine.startRecording()
        await capture.waitUntilStartRequested()
        async let stopped = engine.stopRecording()
        await capture.resumeStart()
        _ = await (starting, stopped)

        #expect(await capture.startCount == 1)
        #expect(completedResult(engine)?.outcome == .noSpeech)
        #expect(!engine.isRecordingBusy)
    }

    @Test func sessionConfigurationDoesNotChangeMidRecording() async {
        let capture = FakeAudioCapture()
        let engine = makeEngine(transcriber: FakeTranscriber(result: "hello"), capture: capture)
        let originalOutput = URL(fileURLWithPath: "/tmp/hover-original", isDirectory: true)
        engine.inputSource = .both

        await engine.startRecording(outputDirectory: originalOutput)
        engine.inputSource = .microphone

        guard case .recording(let state) = engine.recordingPhase else {
            Issue.record("Expected a recording session")
            return
        }
        #expect(state.requestedInputSource == .both)
        #expect(state.activeInputSource == .both)
        #expect(state.outputURL.deletingLastPathComponent() == originalOutput)
        _ = await engine.stopRecording()
    }

    @Test func noSpeechCompletesWithoutASavedPath() async {
        let capture = FakeAudioCapture()
        let engine = makeEngine(transcriber: FakeTranscriber(result: ""), capture: capture)

        await engine.startRecording()
        _ = await engine.stopRecording()

        #expect(completedResult(engine)?.outcome == .noSpeech)
        #expect(completedResult(engine)?.body.isEmpty == true)
    }

    @Test func cancellationRemovesTheSessionDraft() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hover-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = FakeAudioCapture()
        let engine = makeEngine(
            transcriber: FakeTranscriber(result: "draft text"),
            capture: capture,
            transcriptStore: FileTranscriptStore()
        )
        await engine.startRecording(outputDirectory: directory)
        guard case .recording(let state) = engine.recordingPhase else {
            Issue.record("Expected a recording session")
            return
        }
        await capture.emit(AudioChunk(samples: [0.5], startTime: 0, endTime: 1))
        _ = await waitForCommitted(engine, equals: ["draft text"])
        #expect(FileManager.default.fileExists(atPath: state.outputURL.path))

        await engine.cancelRecording()

        #expect(!FileManager.default.fileExists(atPath: state.outputURL.path))
        #expect(engine.recordingPhase == .idle)
    }

    @Test func failedWriteDoesNotPublishASavedRecording() async {
        let final = AudioChunk(samples: [0.5], startTime: 0, endTime: 1)
        let engine = makeEngine(
            transcriber: FakeTranscriber(result: "important words"),
            capture: FakeAudioCapture(chunkOnStop: final),
            transcriptStore: FailingWriteTranscriptStore()
        )
        await engine.startRecording()

        let result = await engine.stopRecording()

        #expect(result?.path == nil)
        #expect(result?.failure?.kind == .persistence)
        #expect(engine.presentedFailureMessage != nil)
        guard case .failed(let failure) = engine.recordingPhase else {
            Issue.record("A persistence failure must fail the recording")
            return
        }
        #expect(failure.kind == .persistence)
    }

    @Test func bothModeLabelsMicAndSystemTracks() async {
        let capture = FakeAudioCapture()
        let engine = makeEngine(
            transcriber: SourceMarkerTranscriber(),
            capture: capture,
            inputSource: .both
        )
        await engine.startRecording()
        await capture.emit(
            AudioChunk(samples: [0.5], startTime: 0, endTime: 1, source: .microphone)
        )
        await capture.emit(
            AudioChunk(samples: [0.25], startTime: 1.5, endTime: 3, source: .system)
        )

        let expected = """
            **Mic:** from mic

            **System:** from system
            """
        #expect(await waitForCommitted(engine, equals: [expected]) == [expected])
        #expect(engine.committedText == expected)

        let result = await engine.stopRecording()
        #expect(result?.body == expected)
    }

    @Test func singleSourceStaysUnlabeled() async {
        let capture = FakeAudioCapture()
        let engine = makeEngine(
            transcriber: FakeTranscriber(result: "plain words"),
            capture: capture,
            inputSource: .system
        )
        await engine.startRecording()
        await capture.emit(
            AudioChunk(samples: [0.5], startTime: 0, endTime: 1, source: .system)
        )
        #expect(await waitForCommitted(engine, equals: ["plain words"]) == ["plain words"])
        #expect(!engine.committedText.contains("**"))
    }
}
