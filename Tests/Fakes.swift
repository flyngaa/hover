import Foundation
@testable import TranscriberKit

/// Shared test doubles used across the engine-level suites. They let the engine
/// run with no whisper-cli, no audio devices, and no real disk access.

/// Returns a canned result instead of shelling out to `whisper-cli`.
struct FakeTranscriber: Transcriber {
    let result: String
    func transcribe(samples: [Float]) throws -> String { result }
}

/// In-memory no-op store so the engine never touches the real filesystem.
struct FakeTranscriptStore: TranscriptStore {
    func load(in directory: URL) -> TranscriptLibrary { TranscriptLibrary(transcripts: [], groups: []) }
    func rename(_ transcript: SavedTranscript, to newName: String) -> URL? { nil }
    func move(_ transcript: SavedTranscript, toGroup group: String?, in directory: URL) -> URL? { nil }
    func relocate(_ transcripts: [SavedTranscript], to directory: URL) -> Int { 0 }
    func delete(_ transcript: SavedTranscript) {}
    func matches(_ transcript: SavedTranscript, query: String) -> Bool { false }
    func content(of transcript: SavedTranscript) -> String { "" }
    func write(title: String, body: String, to url: URL) {}
}

/// Reports canned vaults so tests never read the real Obsidian config.
struct FakeVaultFinder: VaultFinder {
    let vaults: [ObsidianVault]
    init(paths: [String] = []) {
        self.vaults = paths.map { ObsidianVault(path: URL(fileURLWithPath: $0, isDirectory: true)) }
    }
    func discoverVaults() -> [ObsidianVault] { vaults }
}

/// Feeds chunks through the same callbacks the real capture uses.
final class FakeAudioCapture: AudioCapture {
    var onChunk: ((AudioChunk) -> Void)?
    var onStatus: ((CaptureStatus) -> Void)?
    func start(inputSource: InputSource, retainFullRecording: Bool) async throws -> CaptureOutcome {
        CaptureOutcome(systemStarted: true, micStarted: true)
    }
    func stop() -> [Float]? { nil }
    func noteTranscriptionFinished() {}

    /// Test helper: simulate the capture emitting a ready chunk.
    func emit(_ chunk: AudioChunk) { onChunk?(chunk) }
}
