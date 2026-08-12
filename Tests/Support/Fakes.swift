import Foundation
import HoverCore
import HoverPlatform

@testable import HoverApp

/// Shared test doubles used across the engine-level suites. They let the engine
/// run with no whisper-cli, no audio devices, and no real disk access.

/// Returns a canned result instead of shelling out to `whisper-cli`.
struct FakeTranscriber: Transcriber {
    let result: String
    /// Always ready — which is also what makes the engine tests independent of
    /// whether this machine happens to have whisper-cli installed.
    var unavailableReason: String? { nil }
    func transcribe(samples: [Float]) async throws -> String { result }
}

/// In-memory no-op store so the engine never touches the real filesystem.
struct FakeTranscriptStore: TranscriptStore {
    func availableRecordingDestination(
        for date: Date,
        in directory: URL
    ) -> (title: String, url: URL) {
        let title = TranscriptDocument.title(for: date)
        return (title, directory.appendingPathComponent(title).appendingPathExtension("md"))
    }

    func load(in directory: URL) throws -> TranscriptLibrary {
        TranscriptLibrary(transcripts: [], groups: [])
    }
    func rename(_ transcript: SavedTranscript, to newName: String) throws -> SavedTranscript {
        transcript
    }
    func move(
        _ transcript: SavedTranscript,
        toGroup group: String?,
        in directory: URL
    ) throws -> SavedTranscript {
        transcript
    }
    func relocate(
        _ transcripts: [SavedTranscript],
        to directory: URL
    ) -> TranscriptRelocationReport {
        TranscriptRelocationReport(unchanged: transcripts)
    }
    func delete(_ transcript: SavedTranscript) throws {}
    func matches(_ transcript: SavedTranscript, query: String) -> Bool { false }
    func content(of transcript: SavedTranscript) throws -> String { "" }
    func write(title: String, body: String, to url: URL) throws {}
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
actor FakeAudioCapture: AudioCapture {
    private var continuation: AsyncStream<AudioCaptureEvent>.Continuation?
    private let chunkOnStop: AudioChunk?
    private let suspendsStart: Bool
    private let systemStarts: Bool
    private let startErrorDescription: String?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    /// What the engine asked to capture, or nil if it never started.
    private(set) var startedInputSource: InputSource?
    private(set) var startCount = 0

    init(
        chunkOnStop: AudioChunk? = nil,
        suspendsStart: Bool = false,
        systemStarts: Bool = true,
        startErrorDescription: String? = nil
    ) {
        self.chunkOnStop = chunkOnStop
        self.suspendsStart = suspendsStart
        self.systemStarts = systemStarts
        self.startErrorDescription = startErrorDescription
    }

    func start(inputSource: InputSource) async throws -> AudioCaptureStart {
        startCount += 1
        if let startErrorDescription {
            throw NSError(
                domain: "FakeAudioCapture",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: startErrorDescription]
            )
        }
        let (events, continuation) = AsyncStream<AudioCaptureEvent>.makeStream()
        self.continuation = continuation
        startedInputSource = inputSource
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if suspendsStart {
            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
        }
        return AudioCaptureStart(
            outcome: CaptureOutcome(
                systemStarted: systemStarts && inputSource != .microphone
            ),
            events: events
        )
    }
    func stop() async {
        if let chunkOnStop { continuation?.yield(.chunk(chunkOnStop)) }
        continuation?.finish()
        continuation = nil
    }
    func noteTranscriptionFinished() async {}

    /// Test helper: simulate the capture emitting a ready chunk.
    func emit(_ chunk: AudioChunk) { continuation?.yield(.chunk(chunk)) }

    func waitUntilStartRequested() async {
        if startCount > 0 { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resumeStart() {
        startContinuation?.resume()
        startContinuation = nil
    }
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

    func noteScreenRecordingAccess(_ state: PermissionState) {
        screenRecording = state
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

    func fetchMissing() -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                fetchCount += 1
                let missing = ModelArtifact.allCases.filter { !present.contains($0) }
                lastFetched = missing
                if let fetchError {
                    self.fetchError = nil
                    continuation.finish(throwing: fetchError)
                    return
                }
                continuation.yield(0.5)
                continuation.yield(1.0)
                present = Set(ModelArtifact.allCases)
                continuation.finish()
            }
        }
    }
}
