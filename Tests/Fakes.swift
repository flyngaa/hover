import Foundation
@testable import TranscriberKit

/// Shared test doubles used across the engine-level suites. They let the engine
/// run with no whisper-cli, no audio devices, and no real disk access.

/// Returns a canned result instead of shelling out to `whisper-cli`.
struct FakeTranscriber: Transcriber {
    let result: String
    /// Always ready — which is also what makes the engine tests independent of
    /// whether this machine happens to have whisper-cli installed.
    var unavailableReason: String? { nil }
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

    /// What the engine asked to capture, or nil if it never started.
    private(set) var startedInputSource: InputSource?

    func start(inputSource: InputSource, retainFullRecording: Bool) async throws -> CaptureOutcome {
        startedInputSource = inputSource
        return CaptureOutcome(systemStarted: inputSource != .microphone)
    }
    func stop() -> [Float]? { nil }
    func noteTranscriptionFinished() {}

    /// Test helper: simulate the capture emitting a ready chunk.
    func emit(_ chunk: AudioChunk) { onChunk?(chunk) }
}

/// Canned permission answers, so tests can drive every macOS refusal without
/// touching this Mac's real privacy settings.
final class FakeRecordingPermissions: RecordingPermissions {
    var microphone: PermissionState
    var screenRecording: PermissionState

    /// What the microphone prompt turns `notRequested` into.
    var microphoneAnswer: PermissionState = .granted

    private(set) var microphoneRequests = 0
    private(set) var screenRecordingRequests = 0
    private(set) var settingsOpened: [RecordingPermission] = []
    private(set) var relaunches = 0

    init(microphone: PermissionState = .granted, screenRecording: PermissionState = .granted) {
        self.microphone = microphone
        self.screenRecording = screenRecording
    }

    func requestMicrophone() async -> PermissionState {
        microphoneRequests += 1
        if microphone == .notRequested { microphone = microphoneAnswer }
        return microphone
    }

    /// Mirrors the real thing: the prompt is shown, but the grant only reaches
    /// the *next* launch, so the state stays where it was.
    func requestScreenRecording() {
        screenRecordingRequests += 1
        if screenRecording == .notRequested { screenRecording = .denied }
    }

    func openSettings(for permission: RecordingPermission) {
        settingsOpened.append(permission)
    }

    func relaunch() {
        relaunches += 1
    }
}

/// In-memory Model Setup so engine tests never hit the network or disk.
///
/// Configure which artifacts are already present and ``fetchError`` to drive
/// the setup flows the engine orchestrates (required / skipped / fail / Retry).
final class FakeModelSetup: ModelSetup {
    /// Artifacts already on hand. ``isComplete`` is derived from this set.
    var present: Set<ModelArtifact>
    /// When non-nil, the next ``fetchMissing`` call throws this and clears it,
    /// so a following Retry can succeed.
    var fetchError: Error?
    /// How many times ``fetchMissing`` has been called.
    private(set) var fetchCount = 0
    /// Artifacts requested on the most recent fetch — should be only the gaps.
    private(set) var lastFetched: [ModelArtifact] = []

    var isComplete: Bool {
        present.count == ModelArtifact.allCases.count
    }

    init(isComplete: Bool = true) {
        self.present = isComplete ? Set(ModelArtifact.allCases) : []
    }

    init(present: Set<ModelArtifact>) {
        self.present = present
    }

    func fetchMissing(progress: @escaping @Sendable (Double) -> Void) async throws {
        fetchCount += 1
        let missing = ModelArtifact.allCases.filter { !present.contains($0) }
        lastFetched = missing
        if let fetchError {
            self.fetchError = nil
            throw fetchError
        }
        progress(0.5)
        progress(1.0)
        present = Set(ModelArtifact.allCases)
    }
}
