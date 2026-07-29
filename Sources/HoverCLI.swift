import Foundation
import AppKit

/// Runs Hover headlessly for agent / command-line use: start recording right
/// away, stop on a duration or Ctrl-C, print the transcript to stdout, and exit.
///
/// No dock icon and no window — the app runs as a background accessory so it can
/// be driven from a tool like Claude Code without stealing focus.
enum HoverCLI {

    /// Entry point from `main`. Never returns (drives the AppKit run loop, then
    /// exits from inside the delegate).
    static func run(_ options: CLIOptions) -> Never {
        if options.help {
            print(CLIOptions.helpText)
            exit(0)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory) // no dock icon, no window
        let delegate = Delegate(options: options)
        app.delegate = delegate
        app.run()
        exit(0) // not reached; the delegate exits when the pipeline finishes
    }

    // MARK: - Delegate that drives the pipeline

    private final class Delegate: NSObject, NSApplicationDelegate {
        private let options: CLIOptions
        private let engine = TranscriberEngine()
        private var signalSources: [DispatchSourceSignal] = []

        init(options: CLIOptions) {
            self.options = options
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            Task { @MainActor in await self.execute() }
        }

        @MainActor
        private func execute() async {
            applyOverrides()

            printStatus("Recording \(durationLabel)…")
            await engine.startRecording()
            guard engine.isRecording else {
                fail(engine.authError ?? "Failed to start recording.")
            }

            await waitForStop()

            printStatus("Transcribing…")
            engine.stopRecording()
            await waitForTranscriptionToSettle()

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

        @MainActor
        private func waitForStop() async {
            if let duration = options.duration {
                try? await Task.sleep(for: .seconds(duration))
            } else {
                await waitForInterrupt()
            }
        }

        /// Suspend until SIGINT (Ctrl-C) or SIGTERM arrives.
        @MainActor
        private func waitForInterrupt() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                var resumed = false
                let resume = {
                    guard !resumed else { return }
                    resumed = true
                    self.signalSources.forEach { $0.cancel() }
                    continuation.resume()
                }
                for sig in [SIGINT, SIGTERM] {
                    signal(sig, SIG_IGN) // stop the default terminate behaviour
                    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                    source.setEventHandler { resume() }
                    source.resume()
                    signalSources.append(source)
                }
            }
        }

        /// After Stop, the final chunk may still be transcribing on a background
        /// queue, and speaker tagging (if on) runs afterwards. Wait until things
        /// settle so the saved transcript is complete before we read it.
        @MainActor
        private func waitForTranscriptionToSettle() async {
            // 1. Wait for the committed-chunk count to stop growing (last chunk).
            var lastCount = -1
            var stableTicks = 0
            for _ in 0..<200 { // up to ~60s
                let count = engine.committedChunks.count
                if count == lastCount {
                    stableTicks += 1
                    if stableTicks >= 3 { break }
                } else {
                    stableTicks = 0
                    lastCount = count
                }
                try? await Task.sleep(for: .milliseconds(300))
            }

            // 2. If tagging is on, wait for the post-recording pass to finish.
            if engine.diarizeSpeakers {
                for _ in 0..<360 where engine.statusMessage != "Ready" { // up to ~3 min
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }

        // MARK: Output

        @MainActor
        private func emitResult() {
            let transcript = engine.lastRecordingTranscript
            let text = transcript.map { engine.loadTranscriptContent($0) } ?? ""
            let savedPath = transcript?.path.path

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
            FileHandle.standardError.write(Data(("• " + message + "\n").utf8))
        }

        private func fail(_ message: String) -> Never {
            FileHandle.standardError.write(Data(("Error: " + message + "\n").utf8))
            exit(1)
        }
    }
}
