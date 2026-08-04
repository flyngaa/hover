import Foundation
import Observation

/// `@Observable` (not `ObservableObject`) so views only re-render when a
/// property they actually read changes — the 0.5s status tick no longer
/// invalidates the whole window.
@Observable
final class TranscriberEngine: NSObject {

    // MARK: - Observed state

    var isRecording = false
    /// Title of the recording currently in progress (nil when idle). Drives the
    /// "in progress" shimmer row in the sidebar; stays set through the
    /// post-recording speaker-tagging pass until the final transcript is saved.
    var recordingTitle: String?
    var committedChunks: [String] = []
    var savedTranscripts: [SavedTranscript] = []
    var groups: [String] = []
    var lastRecordingTranscript: SavedTranscript?
    var statusMessage = "Ready"
    var authError: String?

    /// Which transcripts are marked in the sidebar (+ the range-selection anchor).
    /// A pure value type owns the fiddly rules; see ``Selection``.
    var selection = Selection()

    /// How the sidebar reads and writes the selection: SwiftUI's
    /// `List(selection:)` needs a plain `Set` binding, not a value type, so these
    /// forward to ``selection`` rather than exposing it directly.
    var markedTranscriptIDs: Set<String> {
        get { selection.markedIDs }
        set { selection.markedIDs = newValue }
    }
    var selectionAnchorID: String? {
        get { selection.anchorID }
        set { selection.anchorID = newValue }
    }

    // Persisted settings. The stored values below drive the UI (SwiftUI binds to
    // them); each change is written through the injected ``SettingsStore``, and
    // the initial values are loaded from it in `init`.

    var inputSource: InputSource = .both {
        didSet { settings.inputSource = inputSource }
    }

    /// When on, the full recording is analyzed after Stop to label who spoke
    /// ("Speaker 1", "Speaker 2", …). Runs locally; adds processing time.
    var diarizeSpeakers: Bool = false {
        didSet { settings.diarizeSpeakers = diarizeSpeakers }
    }

    /// The single folder transcripts are saved to. Setting it only repoints the
    /// app; moving existing files is a separate, explicit step. Prefer
    /// ``requestOutputChange(to:)`` from the UI so the user is offered the move.
    ///
    /// Stored here rather than read from ``settings`` on demand: the store is
    /// `@ObservationIgnored`, so a computed property over it changed without
    /// SwiftUI noticing and the toolbar went on naming the previous folder.
    var outputDirectory: URL = TranscriberEngine.defaultOutputDirectory {
        didSet {
            settings.outputDirectoryPath = outputDirectory.path
            try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            loadSavedTranscripts()
        }
    }

    /// Set when changing the output folder would leave existing transcripts
    /// behind, so the UI can offer to bring them along. See ``PendingOutputChange``.
    var pendingOutputChange: PendingOutputChange?

    var committedText: String { committedChunks.joined(separator: " ") }

    /// True after Stop while the finished recording is still being worked on
    /// (e.g. the speaker-tagging pass), before the labeled transcript is saved.
    /// `recordingTitle` stays set through that pass; `isRecording` is already off.
    /// Drives the "processing" shimmer over the transcript text.
    var isProcessing: Bool { !isRecording && recordingTitle != nil }

    // MARK: - Configuration

    /// All tunable settings and external tool locations in one place, so there
    /// are no magic numbers or hardcoded paths scattered through the engine.
    /// Whisper's own binary and model live with ``WhisperCLITranscriber``, behind
    /// the transcription seam.
    enum Config {
        /// Whisper expects 16 kHz mono audio.
        static let sampleRate = 16000

        // How captured audio is sliced into chunks sent to Whisper.
        static let maxChunkSeconds: Double = 10       // hard cap before forcing a flush
        static let minChunkSeconds: Double = 3        // shortest chunk we'll flush on a pause
        static let silenceWindowSeconds: Double = 0.7 // trailing window checked for silence
        static let silenceRMSThreshold: Float = 0.004 // below this counts as silence

        /// In Both mode, how much system audio to buffer for mixing with the mic.
        static let systemMixBufferSeconds: Double = 2
    }

    @ObservationIgnored let sampleRate = Config.sampleRate

    /// Turns captured audio samples into text. Injected so tests can supply a
    /// fake instead of the real `whisper-cli`.
    @ObservationIgnored let transcriber: Transcriber

    /// Captures audio and emits ready-to-transcribe chunks. Injected so tests
    /// can drive the engine with canned samples instead of real devices.
    @ObservationIgnored let audioCapture: AudioCapture

    /// Owns transcript files on disk (listing, search, rename/move/delete,
    /// markdown format). Injected so tests can use an in-memory fake.
    @ObservationIgnored let transcriptStore: TranscriptStore

    /// Finds Obsidian vaults to offer as output folders. Injected so tests can
    /// use a fake instead of reading the real Obsidian config.
    @ObservationIgnored let vaultFinder: VaultFinder

    /// Persists user settings (input source, tagging, output folder). Injected so
    /// tests can use an in-memory store instead of the real `UserDefaults`.
    @ObservationIgnored let settings: SettingsStore

    /// Resolved helper and model-data locations. The Transcriber and the
    /// speaker-tagging pass both read from this so release-path changes land in
    /// one place. Injected so tests never touch the real home directory.
    @ObservationIgnored let installLayout: InstallLayout

    // MARK: - Session state
    // @ObservationIgnored: mutated on background queues and never read by views.

    /// Timestamped transcript pieces captured live (only when tagging is on),
    /// so we don't have to re-transcribe the whole recording at Stop.
    /// Written on `transcribeQueue`, the only queue that touches it.
    @ObservationIgnored var sessionSegments: [TextSegment] = []
    @ObservationIgnored let transcribeQueue = DispatchQueue(label: "transcriber.whisper", qos: .userInitiated)
    /// Speaker tagging runs here so a long post-recording pass never blocks the
    /// live transcription of a new recording.
    @ObservationIgnored let diarizeQueue = DispatchQueue(label: "transcriber.diarize", qos: .utility)

    @ObservationIgnored var currentLogPath: URL?
    @ObservationIgnored var chunksTranscribed = 0

    /// Called on the main queue when a stopped recording has been fully processed
    /// and saved: after the last chunk is transcribed and, when speaker tagging is
    /// on, after the labeled transcript has been written. Agent Mode waits on this
    /// before it prints and exits — nothing else tells it the file is final.
    @ObservationIgnored var onRecordingFinished: ((SavedTranscript?) -> Void)?

    static var transcriptsDir: URL { defaultOutputDirectory }

    init(
        transcriber: Transcriber? = nil,
        audioCapture: AudioCapture = LiveAudioCapture(log: { NSLog("[Hover] %@", $0) }),
        transcriptStore: TranscriptStore = FileTranscriptStore(),
        vaultFinder: VaultFinder = ObsidianVaultFinder(),
        settings: SettingsStore = UserDefaultsSettings(),
        installLayout: InstallLayout = .current
    ) {
        self.installLayout = installLayout
        // Default Transcriber shares this layout so helper/model paths can't drift.
        self.transcriber = transcriber ?? WhisperCLITranscriber(
            layout: installLayout,
            log: { NSLog("[Hover] %@", $0) }
        )
        self.audioCapture = audioCapture
        self.transcriptStore = transcriptStore
        self.vaultFinder = vaultFinder
        self.settings = settings
        super.init()

        // Load persisted settings. Assigning inside init doesn't fire the didSet
        // observers, so this reads without immediately writing back.
        inputSource = settings.inputSource
        diarizeSpeakers = settings.diarizeSpeakers
        outputDirectory = Self.savedOutputDirectory(from: settings)

        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        loadSavedTranscripts()
        wireAudioCapture()
    }

    /// Route the capture's chunks into transcription and its status into the UI.
    private func wireAudioCapture() {
        audioCapture.onChunk = { [weak self] chunk in
            guard let self else { return }
            self.transcribeQueue.async {
                self.transcribe(samples: chunk.samples, startTime: chunk.startTime, endTime: chunk.endTime)
                self.audioCapture.noteTranscriptionFinished()
            }
        }
        audioCapture.onStatus = { [weak self] status in
            self?.applyStatus(status)
        }
    }

    func log(_ msg: String) {
        NSLog("[Hover] %@", msg)
    }

    private func commit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        DispatchQueue.main.async {
            if self.committedChunks.last == trimmed { return }
            self.committedChunks.append(trimmed)
            self.persistTranscript()
            self.log("Committed chunk #\(self.committedChunks.count) (\(trimmed.count) chars)")
        }
    }

    func persistTranscript() {
        guard let path = currentLogPath else { return }
        let title = path.deletingPathExtension().lastPathComponent
        transcriptStore.write(title: title, body: committedText, to: path)
    }

    // MARK: - Recording lifecycle

    func startRecording() async {
        if let reason = transcriber.unavailableReason {
            await MainActor.run { authError = reason }
            return
        }

        await MainActor.run {
            committedChunks = []
            authError = nil
        }
        chunksTranscribed = 0
        sessionSegments = []

        let title = FileTranscriptStore.title(for: Date())
        let logURL = outputDirectory.appendingPathComponent("\(title).\(FileTranscriptStore.outputFileExtension)")
        currentLogPath = logURL
        // The file is written lazily on the first committed chunk (see persistTranscript),
        // so a recording that captures no speech never leaves an empty transcript behind.
        log("Saving to: \(logURL.path)")
        log("Input source: \(inputSource.label)")

        do {
            let outcome = try await audioCapture.start(
                inputSource: inputSource,
                retainFullRecording: diarizeSpeakers
            )
            // Both mode tolerates missing system audio (keeps the mic), but the
            // user should know why the recording is mic-only.
            if inputSource == .both && !outcome.systemStarted {
                await MainActor.run {
                    authError = "System audio couldn't be captured (Screen Recording permission is off), so Hover is recording the microphone only.\n\nTo include system audio: System Settings > Privacy & Security > Screen Recording, enable Hover, then relaunch."
                }
            }
            await MainActor.run {
                isRecording = true
                recordingTitle = title
                statusMessage = "Recording..."
            }
        } catch {
            log("ERROR: \(error.localizedDescription)")
            await MainActor.run {
                authError = "Failed to start: \(error.localizedDescription)"
            }
        }
    }

    func stopRecording() {
        log("Stopping — chunks:\(chunksTranscribed)")

        // stop() flushes the final chunk (handed to transcription) and returns
        // the full recording if it was retained for speaker tagging.
        let fullRecording = audioCapture.stop()

        isRecording = false

        if diarizeSpeakers {
            beginDiarizationPass(samples: fullRecording ?? [])
        } else {
            finishRecording(path: currentLogPath)
        }
    }

    /// Reloads the transcript list and runs post-recording side effects.
    /// `path` is passed explicitly because the diarization pass clears
    /// `currentLogPath` to prevent late writes from clobbering the result.
    func finishRecording(path: URL?) {
        statusMessage = "Ready"
        // The real saved transcript now takes over from the in-progress row.
        recordingTitle = nil
        loadSavedTranscripts()

        if let path {
            // Resolve both sides before comparing: the store's URLs come back from
            // the filesystem, so an output folder reached through a symlink (a
            // linked vault, /tmp) spells the same file a different way and the
            // just-saved transcript would look like someone else's.
            let target = path.resolvingSymlinksInPath()
            lastRecordingTranscript = savedTranscripts.first {
                $0.path.resolvingSymlinksInPath() == target
            }

            // The just-finished recording keeps showing in the live view
            // (committedText is still non-empty). Refresh that text from the
            // saved file so the speaker labels added by the post-recording pass
            // ("Speaker 1: …", "Speaker 2: …") replace the unlabeled live text
            // on screen, instead of only living in the file on disk.
            if let last = lastRecordingTranscript {
                let finalText = loadTranscriptContent(last)
                if !finalText.isEmpty { committedChunks = [finalText] }
            }
        }

        onRecordingFinished?(lastRecordingTranscript)
    }

    /// Builds the "Recording — sys ✓ · mic ✓ · chunks: N · transcribing…" line
    /// from the capture's status plus the engine's own chunk count. Runs on the
    /// main queue (the capture delivers status there).
    private func applyStatus(_ status: CaptureStatus) {
        guard isRecording else { return }
        var parts: [String] = []
        if inputSource != .microphone { parts.append(status.systemActive ? "sys ✓" : "sys: waiting") }
        if inputSource != .system { parts.append(status.micActive ? "mic ✓" : "mic: waiting") }
        parts.append("chunks: \(chunksTranscribed)")
        if status.transcribing { parts.append("transcribing…") }
        statusMessage = "Recording — \(parts.joined(separator: " · "))"
    }

    func transcribe(samples: [Float], startTime: Double = 0, endTime: Double = 0) {
        let text: String
        do {
            text = try transcriber.transcribe(samples: samples)
        } catch {
            log("Transcription failed: \(error.localizedDescription)")
            return
        }
        // Empty means silence or a hallucinated fragment — nothing worth saving.
        guard !text.isEmpty else { return }

        chunksTranscribed += 1

        // Keep the chunk's timing (only when tagging is on) so the speaker pass
        // can align text to speakers without re-transcribing. Runs on
        // transcribeQueue, the only place sessionSegments is written.
        if diarizeSpeakers {
            sessionSegments.append(TextSegment(start: startTime, end: endTime, text: text))
        }
        commit(text)
    }
}
