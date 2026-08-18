import AppKit
import Foundation
import HoverCore

struct CLIProcessResult: Equatable, Sendable {
    let exitCode: Int32
    let standardError: String
}

enum CLISetupAction: Equatable, Sendable {
    case fetch
    case finish(CLIProcessResult)
}

struct CLIOutput: Sendable {
    let standardOutput: @Sendable (String) -> Void
    let standardError: @Sendable (String) -> Void
}

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

    private static let modelDataReadyResult = CLIProcessResult(
        exitCode: 0,
        standardError: "Model data is ready.\n"
    )

    static func setupAction(isComplete: Bool, statusOnly: Bool) -> CLISetupAction {
        if isComplete {
            return .finish(modelDataReadyResult)
        }
        if statusOnly {
            return .finish(
                CLIProcessResult(
                    exitCode: 1,
                    standardError:
                        "Model data is missing. Run `hover setup` to download about 575 MB.\n"
                ))
        }
        return .fetch
    }

    static func setupCompletion(
        isComplete: Bool,
        errorDescription: String?
    ) -> CLIProcessResult {
        if isComplete {
            return modelDataReadyResult
        }
        let message = errorDescription ?? "Downloaded model data is incomplete."
        return CLIProcessResult(
            exitCode: 1,
            standardError: "Model Setup failed: \(message)\n"
        )
    }

    /// Executes only setup-related routes. Returning `nil` leaves record/GUI
    /// routing to the caller. Model Setup and process streams are injected so
    /// tests exercise the same fetch and output path as Agent Mode.
    @MainActor
    static func executeSetup(
        _ options: CLIOptions,
        modelSetup: ModelSetup,
        output: CLIOutput
    ) async -> Int32? {
        let statusOnly: Bool
        switch options.command {
        case .setup(let requestedStatusOnly):
            statusOnly = requestedStatusOnly
        case .invalid:
            output.standardError(
                "Error: Unsupported setup option. Use `hover setup` or `hover setup --status`.\n"
            )
            return 1
        case .gui, .record, .doctor:
            return nil
        }

        switch setupAction(isComplete: modelSetup.isComplete, statusOnly: statusOnly) {
        case .finish(let result):
            output.standardError(result.standardError)
            return result.exitCode
        case .fetch:
            output.standardError("• Downloading model data…\n")
        }

        var fetchError: String?
        do {
            for try await fraction in modelSetup.fetchMissing() {
                let percent = Int((fraction * 100).rounded())
                output.standardError("• Model Setup: \(percent)%\n")
            }
        } catch {
            fetchError = error.localizedDescription
        }

        let result = setupCompletion(
            isComplete: modelSetup.isComplete,
            errorDescription: fetchError
        )
        output.standardError(result.standardError)
        return result.exitCode
    }

    /// Stderr message when recording is started without model data. Points at
    /// Model Setup rather than hanging on an invisible download.
    static let modelDataMissingMessage =
        "Model data isn't set up yet. Run `hover setup` to download "
        + "about 575 MB of models, then try `hover record` again."

    /// `nil` when Agent Mode may proceed; otherwise the stderr message to print
    /// before exiting non-zero. Never starts a download.
    @MainActor
    static func modelDataMissingReason(for modelSetup: any ModelSetup) -> String? {
        modelSetup.isComplete ? nil : modelDataMissingMessage
    }

    // MARK: - Doctor

    /// Assemble the readiness report from already-gathered facts. Pure so the
    /// mapping from raw state to statuses, fixes, and the overall exit code can
    /// be unit-tested without a machine in any particular state. The platform
    /// side (``Delegate/buildDoctorReport()``) reads the live values and calls
    /// this; it must never trigger a permission prompt or a download.
    static func doctorReport(
        architecture: String,
        architectureSupported: Bool,
        osVersion: String,
        osSupported: Bool,
        hoverOnPath: String?,
        modelPresent: Bool,
        microphone: PermissionState,
        systemAudio: PermissionState,
        outputDirectory: String,
        outputWritable: Bool
    ) -> DoctorReport {
        var checks: [DoctorReport.Check] = []

        checks.append(
            DoctorReport.Check(
                id: "architecture",
                name: "Architecture",
                status: architectureSupported ? .ok : .fail,
                detail: architectureSupported
                    ? "\(architecture) (Apple Silicon)"
                    : "\(architecture) is not supported",
                fix: architectureSupported ? nil : "Hover requires an Apple Silicon Mac."
            ))

        checks.append(
            DoctorReport.Check(
                id: "macos",
                name: "macOS",
                status: osSupported ? .ok : .fail,
                detail: osSupported ? osVersion : "\(osVersion) is older than 14.2",
                fix: osSupported ? nil : "Update to macOS 14.2 Sonoma or later."
            ))

        if let path = hoverOnPath {
            checks.append(
                DoctorReport.Check(
                    id: "cli",
                    name: "CLI on PATH",
                    status: .ok,
                    detail: "hover resolves at \(path)"
                ))
        } else {
            checks.append(
                DoctorReport.Check(
                    id: "cli",
                    name: "CLI on PATH",
                    status: .warn,
                    detail: "hover is not on your PATH",
                    fix:
                        "Reinstall the Homebrew cask, or use Hover > Settings > Install CLI. "
                        + "You can still run Hover by its full path."
                ))
        }

        checks.append(
            DoctorReport.Check(
                id: "model",
                name: "Model data",
                status: modelPresent ? .ok : .fail,
                detail: modelPresent
                    ? "Whisper model is downloaded"
                    : "Whisper model data is missing",
                fix: modelPresent ? nil : "Run `hover setup` to download about 575 MB."
            ))

        checks.append(microphoneCheck(microphone))
        checks.append(systemAudioCheck(systemAudio))

        checks.append(
            DoctorReport.Check(
                id: "output",
                name: "Output folder",
                status: outputWritable ? .ok : .fail,
                detail: outputWritable
                    ? "\(outputDirectory) is writable"
                    : "\(outputDirectory) can't be written to",
                fix: outputWritable
                    ? nil
                    : "Open Hover once and pick a writable output folder, or pass "
                        + "--output to a folder Hover can write to."
            ))

        return DoctorReport(checks: checks)
    }

    /// The microphone is Hover's baseline source, so a refusal fails the report;
    /// "not requested" is only a warning because the first recording (or opening
    /// the app) still prompts for it.
    private static func microphoneCheck(_ state: PermissionState) -> DoctorReport.Check {
        switch state {
        case .granted:
            return DoctorReport.Check(
                id: "microphone", name: "Microphone", status: .ok, detail: "granted")
        case .notRequested:
            return DoctorReport.Check(
                id: "microphone",
                name: "Microphone",
                status: .warn,
                detail: "not requested yet",
                fix: "Open Hover and start a recording once so macOS prompts for the microphone."
            )
        case .denied:
            return DoctorReport.Check(
                id: "microphone",
                name: "Microphone",
                status: .fail,
                detail: "denied",
                fix: "Enable Hover under System Settings > Privacy & Security > Microphone."
            )
        }
    }

    /// System audio only ever warns: a `both` recording falls back to mic-only
    /// when it is missing, so its absence degrades a recording rather than
    /// blocking one.
    private static func systemAudioCheck(_ state: PermissionState) -> DoctorReport.Check {
        switch state {
        case .granted:
            return DoctorReport.Check(
                id: "systemAudio", name: "System audio", status: .ok, detail: "granted")
        case .notRequested:
            return DoctorReport.Check(
                id: "systemAudio",
                name: "System audio",
                status: .warn,
                detail: "not requested yet",
                fix:
                    "Open Hover and record System Audio once so macOS prompts. "
                    + "Mic-only recording works without it."
            )
        case .denied:
            return DoctorReport.Check(
                id: "systemAudio",
                name: "System audio",
                status: .warn,
                detail: "denied",
                fix:
                    "Enable Hover under System Settings > Privacy & Security > "
                    + "Screen & System Audio Recording. Mic-only recording works without it."
            )
        }
    }

    // MARK: - Output destination

    /// `nil` when a run may save where it is pointed; otherwise the stderr
    /// message to print before exiting. Checked on every run so a headless run
    /// fails before recording rather than after, when the audio only exists in
    /// memory. `authorizationRequest` is the folder the GUI would raise a picker
    /// for; a headless run has no picker, so it is a hard stop.
    static func outputBlockReason(
        authorizationRequest: URL?,
        failureMessage: String?
    ) -> String? {
        if let failureMessage { return failureMessage }
        if let authorizationRequest {
            return
                "Can't write to \(authorizationRequest.path). Pass --output to a folder Hover "
                + "can write to, or open Hover once and pick an accessible output folder."
        }
        return nil
    }

    /// Entry point from `main`. Never returns (drives the AppKit run loop, then
    /// exits from inside the delegate).
    @MainActor
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
        app.setActivationPolicy(.accessory)  // no dock icon, no window
        let delegate = Delegate(options: options)
        app.delegate = delegate
        // Before the run loop, so a hangup during AppKit's launch is still caught.
        delegate.installStopSignals()
        app.run()
        exit(0)  // not reached; the delegate exits when the pipeline finishes
    }

    // MARK: - Delegate that drives the pipeline

    @MainActor
    private final class Delegate: NSObject, NSApplicationDelegate {
        private let options: CLIOptions
        private let modelSetup: any ModelSetup
        private let permissions: any RecordingPermissions
        private let recording: RecordingModel
        private let transcriptLibrary: TranscriptLibraryModel
        private let presence = RecordingPresence()
        private var signalSources: [DispatchSourceSignal] = []

        private var stopRequested = false
        private let stopEvents: AsyncStream<Void>
        private let stopContinuation: AsyncStream<Void>.Continuation
        private var finalResult: RecordingResult?

        init(options: CLIOptions) {
            self.options = options
            let dependencies = AppDependencies.live()
            modelSetup = dependencies.modelSetup
            permissions = dependencies.permissions
            recording = dependencies.makeRecordingModel()
            transcriptLibrary = dependencies.makeTranscriptLibraryModel()
            (stopEvents, stopContinuation) = AsyncStream.makeStream()
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            Task { @MainActor in await self.execute() }
        }

        @MainActor
        private func execute() async {
            let output = CLIOutput(
                standardOutput: { print($0, terminator: "") },
                standardError: { text in HoverCLI.writeToStandardError(text) }
            )

            if case .doctor(let json) = options.command {
                runDoctor(json: json)  // reports readiness and exits; never records
            }

            if let exitCode = await HoverCLI.executeSetup(
                options,
                modelSetup: modelSetup,
                output: output
            ) {
                exit(exitCode)
            }

            applyOverrides()

            // Agent Mode never runs setup — a missing model tree fails fast so a
            // script doesn't hang on an invisible ~575 MB download.
            if let reason = HoverCLI.modelDataMissingReason(for: modelSetup) {
                fail(reason)
            }

            // The only visible sign of a headless run: without it there's nothing
            // on screen to say the Mac is listening. It lives as long as the run.
            // Skip it when another Hover (the GUI app, a dev build, or a second
            // run) is already showing a moth, so the menu bar never sprouts two.
            let statusItemController = StatusItemController()
            if !HoverCLI.anotherHoverInstanceIsRunning() {
                // A headless run is already recording, so its only control is
                // Stop — the same as Ctrl-C, but from the menu bar.
                statusItemController.show(supporting: [.stopRecording]) { [weak self] command in
                    if command == .stopRecording { self?.noteStopRequested() }
                }
            }

            printStatus("Recording \(durationLabel)…")
            await recording.startRecording(outputDirectory: transcriptLibrary.outputDirectory)
            await answerPermissionRequest()
            guard recording.isRecording else {
                fail(recording.presentedFailureMessage ?? "Failed to start recording.")
            }
            // Announce alongside every render so a GUI moth (which may own the
            // menu bar instead of this run) reflects the recording too.
            statusItemController.render(
                StatusItemSnapshot(
                    activity: .recording,
                    tooltip: "Hover — recording"
                ))
            presence.announce(.recording)

            await waitForStop()

            printStatus("Transcribing…")
            statusItemController.render(
                StatusItemSnapshot(
                    activity: .processing,
                    tooltip: "Hover — processing"
                ))
            presence.announce(.processing)
            finalResult = await recording.stopRecording()
            statusItemController.render(StatusItemSnapshot(activity: .idle, tooltip: "Hover"))
            presence.announce(.idle)

            if let failure = finalResult?.failure {
                fail(failure.message)
            }

            exit(emitResult())
        }

        /// A headless run has nobody to answer a permission dialog and no window
        /// to put one in, so it decides for itself: say what macOS is withholding
        /// and record with whatever is left, or give up when nothing is.
        @MainActor
        private func answerPermissionRequest() async {
            guard let request = recording.permissionRequest else { return }
            printStatus(request.consoleSummary)
            guard let fallback = request.fallback else {
                fail(request.title)
            }
            printStatus("Recording \(fallback.label.lowercased()) only.")
            await recording.recordWithReducedInput()
        }

        // MARK: Doctor

        /// Print the readiness report and exit. Reads state only — never prompts
        /// for a permission and never starts a download.
        @MainActor
        private func runDoctor(json: Bool) -> Never {
            let report = buildDoctorReport()
            if json {
                do {
                    print(try report.jsonReport())
                } catch {
                    fail("Could not encode doctor JSON output.")
                }
            } else {
                print(report.textReport)
            }
            exit(report.exitCode)
        }

        @MainActor
        private func buildDoctorReport() -> DoctorReport {
            #if arch(arm64)
                let architecture = "arm64"
                let architectureSupported = true
            #else
                let architecture = "x86_64"
                let architectureSupported = false
            #endif

            let version = ProcessInfo.processInfo.operatingSystemVersion
            let osVersion =
                "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            let osSupported = (version.majorVersion, version.minorVersion) >= (14, 2)

            return HoverCLI.doctorReport(
                architecture: architecture,
                architectureSupported: architectureSupported,
                osVersion: osVersion,
                osSupported: osSupported,
                hoverOnPath: HoverCLI.hoverExecutableOnPath(),
                modelPresent: modelSetup.isComplete,
                microphone: permissions.microphone,
                systemAudio: permissions.screenRecording,
                outputDirectory: transcriptLibrary.outputDirectory.path,
                outputWritable: transcriptLibrary.outputDirectoryAuthorizationRequest == nil
            )
        }

        // MARK: Setup

        @MainActor
        private func applyOverrides() {
            if let source = options.inputSource { recording.inputSource = source }
            if let output = options.output {
                transcriptLibrary.setOutputDirectory(resolveOutput(output))
            }
            // Checked whether or not --output was passed: the default folder
            // (~/Documents/Transcripts) is itself protected, so a headless run
            // must learn it can't save now rather than after a recording, when
            // the audio only exists in memory.
            if let reason = HoverCLI.outputBlockReason(
                authorizationRequest: transcriptLibrary.outputDirectoryAuthorizationRequest,
                failureMessage: transcriptLibrary.presentedFailureMessage
            ) {
                fail(reason)
            }
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

            if let match = transcriptLibrary.availableVaults.first(where: {
                $0.name.caseInsensitiveCompare(value) == .orderedSame
            }) {
                return match.transcriptsFolder
            }

            let known = transcriptLibrary.availableVaults.map(\.name).joined(separator: ", ")
            fail(
                "'\(value)' is neither a folder path nor a known Obsidian vault. "
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
                signal(sig, SIG_IGN)  // replace the default terminate behaviour
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
            stopContinuation.yield(())
            for source in signalSources { source.cancel() }
            signalSources = []
            // Hand Ctrl-C and `kill` back to the system, so a run that gets stuck
            // can still be forced to quit. SIGHUP stays ignored: a terminal being
            // torn down can send several, and nobody is watching to retry — the
            // final transcription flush has to be allowed to finish.
            for sig in [SIGINT, SIGTERM] { signal(sig, SIG_DFL) }
        }

        @MainActor
        private func waitForStop() async {
            if stopRequested { return }
            guard let duration = options.duration else {
                for await _ in stopEvents { return }
                return
            }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [stopEvents] in
                    for await _ in stopEvents { return }
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(duration))
                }
                await group.next()
                group.cancelAll()
            }
        }

        // MARK: Output

        /// Returns the process exit code. Non-zero when a transcript was produced
        /// but never reached disk: the text still goes to stdout so it isn't
        /// lost, but the caller must see that the save failed. An empty
        /// transcript (no speech) is not a failure — there was nothing to save.
        @MainActor
        private func emitResult() -> Int32 {
            var text = ""
            var savedPath: String?

            if let result = finalResult {
                text = result.body
                savedPath = result.path?.path
            }

            let saveFailed = !text.isEmpty && savedPath == nil

            if options.json {
                emitJSON(text: text, savedPath: savedPath)
                return saveFailed ? 1 : 0
            }

            if text.isEmpty {
                printStatus("No speech captured — nothing was saved.")
            } else {
                print(text)  // the transcript itself goes to stdout for the agent
            }
            if let savedPath { printStatus("Saved: \(savedPath)") }
            if saveFailed {
                printStatus("Warning: the transcript above could not be saved to a file.")
            }
            // e.g. system audio couldn't start. Without this the run looks clean
            // but quietly skipped something.
            if let warning = recording.presentedFailureMessage {
                printStatus(warning.replacingOccurrences(of: "\n", with: " "))
            }
            return saveFailed ? 1 : 0
        }

        private func emitJSON(text: String, savedPath: String?) {
            struct AgentModeResult: Encodable {
                let transcript: String
                let savedPath: String?
            }

            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(
                    AgentModeResult(
                        transcript: text,
                        savedPath: savedPath
                    ))
                guard let string = String(data: data, encoding: .utf8) else {
                    fail("Could not encode Agent Mode output as UTF-8.")
                }
                print(string)
            } catch {
                fail("Could not encode Agent Mode JSON output.")
            }
        }

        // MARK: Helpers

        /// Status/progress lines go to stderr so stdout stays clean for the
        /// transcript (which an agent will capture).
        private func printStatus(_ message: String) {
            HoverCLI.writeToStandardError("• " + message + "\n")
        }

        private func fail(_ message: String) -> Never {
            HoverCLI.writeToStandardError("Error: " + message + "\n")
            exit(1)
        }

    }

    // MARK: - One moth at a time

    /// Pure decision: is another Hover instance present among `running` (matched
    /// by bundle id), excluding this process? Factored out from
    /// ``anotherHoverInstanceIsRunning()`` so it can be tested without the window
    /// server.
    static func hasOtherInstance(
        ofBundleID myBundleID: String?,
        excludingProcessID myProcessID: Int32,
        among running: [(processID: Int32, bundleID: String?)]
    ) -> Bool {
        guard let myBundleID else { return false }
        return running.contains {
            $0.processID != myProcessID && $0.bundleID == myBundleID
        }
    }

    /// `true` when another Hover process (the GUI app, a dev build, or a second
    /// run) is already registered with the window server, so a headless run can
    /// avoid parking a second menu-bar moth beside it. Excludes this process.
    @MainActor
    static func anotherHoverInstanceIsRunning() -> Bool {
        hasOtherInstance(
            ofBundleID: Bundle.main.bundleIdentifier,
            excludingProcessID: ProcessInfo.processInfo.processIdentifier,
            among: NSWorkspace.shared.runningApplications.map {
                ($0.processIdentifier, $0.bundleIdentifier)
            }
        )
    }

    /// The absolute path of a `hover` executable resolvable on the caller's
    /// PATH, or `nil` when none is. Read-only: it confirms a future
    /// `hover record` in a fresh shell will resolve, without running anything.
    static func hoverExecutableOnPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        guard let path = environment["PATH"] else { return nil }
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent("hover")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }

    /// Uses `write(2)` rather than `FileHandle`, which raises an exception when
    /// the far end has gone away. It is also safe to call from Model Setup's
    /// progress callback without routing output through stdout.
    private static func writeToStandardError(_ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { write(STDERR_FILENO, $0.baseAddress, $0.count) }
    }
}
