import Foundation
import AppKit

/// Runs Hover headlessly for agent / command-line use: start recording right
/// away, stop on a duration or Ctrl-C, print the transcript to stdout, and exit.
///
/// No dock icon and no window — the app runs as a background accessory so it can
/// be driven from a tool like Claude Code without stealing focus.
///
/// A run is expected to outlive the terminal that started it. Closing the window
/// or ending the session means "stop and save", never "drop the recording": the
/// captured audio only exists in memory until the transcript has been written, so
/// dying early throws the whole recording away.
enum HoverCLI {

    /// Stderr message when Agent Mode is started without model data. Tells the
    /// user to open the GUI once rather than hanging on an invisible download.
    static let modelDataMissingMessage =
        "Model data isn't set up yet. Open Hover once to download "
        + "about 600 MB of models, then try again."

    /// `nil` when Agent Mode may proceed; otherwise the stderr message to print
    /// before exiting non-zero. Never starts a download.
    static func modelDataMissingReason(for engine: TranscriberEngine) -> String? {
        engine.modelSetup.isComplete ? nil : modelDataMissingMessage
    }

    /// Entry point from `main`. Never returns (drives the AppKit run loop, then
    /// exits from inside the delegate).
    static func run(_ options: CLIOptions) -> Never {
        if options.help {
            print(CLIOptions.helpText)
            exit(0)
        }

        // Writing to a terminal that has gone away otherwise raises SIGPIPE, whose
        // default action is to kill us — losing a finished recording at the very
        // last step, while printing it. Failed writes are dropped instead.
        signal(SIGPIPE, SIG_IGN)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory) // no dock icon, no window
        let delegate = Delegate(options: options)
        app.delegate = delegate
        // Before the run loop, so a hangup during AppKit's launch is still caught.
        delegate.installStopSignals()
        app.run()
        exit(0) // not reached; the delegate exits when the pipeline finishes
    }

    // MARK: - Delegate that drives the pipeline

    private final class Delegate: NSObject, NSApplicationDelegate {
        private let options: CLIOptions
        private let engine = TranscriberEngine()
        private var signalSources: [DispatchSourceSignal] = []

        /// Set once Ctrl-C / `kill` has arrived. Recorded as a flag rather than
        /// waking a waiter directly, so a Stop that lands while the microphone is
        /// still starting up isn't lost.
        private var stopRequested = false

        /// Set once the engine reports the transcript on disk is final.
        private var recordingFinished = false

        /// How long to give the post-recording work (last chunk + speaker pass)
        /// before printing whatever is on disk and giving up.
        private static let processingTimeout: Double = 300

        init(options: CLIOptions) {
            self.options = options
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            Task { @MainActor in await self.execute() }
        }

        @MainActor
        private func execute() async {
            applyOverrides()

            // Agent Mode never runs setup — a missing model tree fails fast so a
            // script doesn't hang on an invisible 600 MB download.
            if let reason = HoverCLI.modelDataMissingReason(for: engine) {
                fail(reason)
            }

            // The only visible sign of a headless run: without it there's nothing
            // on screen to say the Mac is listening. It lives as long as the run.
            let menuBarMoth = MenuBarMoth()
            menuBarMoth.show()
            menuBarMoth.follow(engine)

            printStatus("Recording \(durationLabel)…")
            await engine.startRecording()
            guard engine.isRecording else {
                fail(engine.authError ?? "Failed to start recording.")
            }

            await waitForStop()

            printStatus(engine.diarizeSpeakers ? "Transcribing and tagging speakers…" : "Transcribing…")
            await stopAndAwaitFinalTranscript()

            emitResult()
            exit(0)
        }

        // MARK: Setup

        @MainActor
        private func applyOverrides() {
            if let source = options.inputSource { engine.inputSource = source }
            if let tag = options.tagSpeakers { engine.diarizeSpeakers = tag }
            if let output = options.output { engine.outputDirectory = resolveOutput(output) }
        }

        /// `--output` is either a folder path or the name of an Obsidian vault
        /// (in which case transcripts go into the vault's Transcripts subfolder).
        @MainActor
        private func resolveOutput(_ value: String) -> URL {
            let looksLikePath = value.hasPrefix("/") || value.hasPrefix("~") || value.hasPrefix(".")
            if looksLikePath {
                return URL(
                    fileURLWithPath: (value as NSString).expandingTildeInPath,
                    isDirectory: true
                ).standardizedFileURL
            }

            if let match = engine.availableVaults.first(where: {
                $0.name.caseInsensitiveCompare(value) == .orderedSame
            }) {
                return match.transcriptsFolder
            }

            let known = engine.availableVaults.map(\.name).joined(separator: ", ")
            fail("'\(value)' is neither a folder path nor a known Obsidian vault. "
                + (known.isEmpty ? "No vaults found." : "Known vaults: \(known)."))
        }

        // MARK: Stopping

        private var durationLabel: String {
            if let duration = options.duration { return "for \(Int(duration))s" }
            return "until Ctrl-C"
        }

        /// Everything that means "stop recording and save": Ctrl-C, `kill`, and the
        /// hangup a closing terminal or an ending session sends. All three used to
        /// be a request to *quit*; only the first two were even handled.
        private static let stopSignals: [Int32] = [SIGINT, SIGTERM, SIGHUP]

        /// Take over the stop signals from the very start of the run — their default
        /// action is to kill the process outright, and both a stop script and a
        /// closing terminal can easily arrive while the microphone is still coming up.
        fileprivate func installStopSignals() {
            for sig in Self.stopSignals {
                signal(sig, SIG_IGN) // replace the default terminate behaviour
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                source.setEventHandler { [weak self] in self?.noteStopRequested() }
                source.resume()
                signalSources.append(source)
            }
        }

        /// The first stop signal ends the recording; the transcript is only saved
        /// once processing finishes, so the run has to stay alive past this point.
        private func noteStopRequested() {
            guard !stopRequested else { return }
            stopRequested = true
            signalSources.forEach { $0.cancel() }
            signalSources = []
            // Hand Ctrl-C and `kill` back to the system, so a run that gets stuck
            // can still be forced to quit. SIGHUP stays ignored: a terminal being
            // torn down can send several, and nobody is watching to retry — the
            // speaker pass has to be allowed to finish.
            for sig in [SIGINT, SIGTERM] { signal(sig, SIG_DFL) }
        }

        @MainActor
        private func waitForStop() async {
            let deadline = options.duration.map { Date().addingTimeInterval($0) }
            while !stopRequested {
                if let deadline, Date() >= deadline { return }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        /// Stop recording, then wait for the engine to say the file on disk is final.
        ///
        /// The engine's completion signal is the only thing worth waiting on here:
        /// when `stopRecording` returns, the last chunk is still being transcribed
        /// on a background queue, and the speaker pass only starts after that. The
        /// callback is armed first because a run without speaker tagging finishes
        /// inline, before `stopRecording` even returns.
        @MainActor
        private func stopAndAwaitFinalTranscript() async {
            engine.onRecordingFinished = { [weak self] _ in self?.recordingFinished = true }
            engine.stopRecording()

            let deadline = Date().addingTimeInterval(Self.processingTimeout)
            while !recordingFinished, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if !recordingFinished {
                printStatus("Gave up waiting after \(Int(Self.processingTimeout))s — "
                    + "saving what's ready, speaker labels may be missing.")
            }
        }

        // MARK: Output

        @MainActor
        private func emitResult() {
            var text = ""
            var savedPath: String?

            if let transcript = engine.lastRecordingTranscript {
                text = engine.loadTranscriptContent(transcript)
                savedPath = transcript.path.path
            }

            // Safety net: fall back to the newest file in the output folder if the
            // engine couldn't tell us which transcript it just saved. Stripped the
            // same way, so stdout looks identical whichever route got us here.
            if text.isEmpty {
                let fm = FileManager.default
                if let contents = try? fm.contentsOfDirectory(at: engine.outputDirectory, includingPropertiesForKeys: [.contentModificationDateKey]),
                   let newestFile = contents
                    .filter({ $0.pathExtension == FileTranscriptStore.outputFileExtension })
                    .max(by: { a, b in
                        let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                        let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                        return aDate < bDate
                    }),
                   let content = try? String(contentsOf: newestFile, encoding: .utf8),
                   !content.isEmpty {
                    text = FileTranscriptStore.displayText(fromFile: content)
                    savedPath = newestFile.path
                }
            }

            if options.json {
                emitJSON(text: text, savedPath: savedPath)
                return
            }

            if text.isEmpty {
                printStatus("No speech captured — nothing was saved.")
            } else {
                print(text) // the transcript itself goes to stdout for the agent
            }
            if let savedPath { printStatus("Saved: \(savedPath)") }
            // e.g. speaker tagging isn't set up, or system audio couldn't start.
            // Without this the run looks clean but quietly skipped something.
            if let warning = engine.authError {
                printStatus(warning.replacingOccurrences(of: "\n", with: " "))
            }
        }

        private func emitJSON(text: String, savedPath: String?) {
            var object: [String: Any] = ["transcript": text]
            object["savedPath"] = savedPath ?? NSNull()
            if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
               let string = String(data: data, encoding: .utf8) {
                print(string)
            }
        }

        // MARK: Helpers

        /// Status/progress lines go to stderr so stdout stays clean for the
        /// transcript (which an agent will capture).
        private func printStatus(_ message: String) {
            writeToStandardError("• " + message + "\n")
        }

        private func fail(_ message: String) -> Never {
            writeToStandardError("Error: " + message + "\n")
            exit(1)
        }

        /// Uses `write(2)` rather than `FileHandle`, which raises an exception when
        /// the far end has gone away — and the terminal that started a long recording
        /// often has by the time we report on it. Nobody is reading, so a dropped
        /// line costs nothing; being killed here would cost the whole recording.
        private func writeToStandardError(_ text: String) {
            let bytes = Array(text.utf8)
            _ = bytes.withUnsafeBufferPointer { write(STDERR_FILENO, $0.baseAddress, $0.count) }
        }
    }
}
