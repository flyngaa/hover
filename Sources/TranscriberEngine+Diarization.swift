import Foundation

/// Speaker tagging ("who spoke when"). After a recording stops, the full audio
/// is analyzed for speaker turns via sherpa-onnx — the native helper when one
/// is present, otherwise the `diar-venv` + `diarize.py` path — and merged with
/// the timestamped text already captured during live transcription. There is
/// no second Whisper pass. The result is a "Speaker 1: … / Speaker 2: …"
/// transcript. Everything runs locally.
extension TranscriberEngine {

    // MARK: - Tooling locations

    /// Paths come from ``installLayout`` so the Transcriber and this pass agree.
    var speakerTaggingHelperPath: String {
        installLayout.speakerTaggingHelper.path
    }
    var diarizationSegModelPath: String {
        installLayout.segmentationModel.path
    }
    var diarizationEmbModelPath: String {
        installLayout.embeddingModel.path
    }
    var diarizationScriptPath: String? {
        Bundle.main.path(forResource: "diarize", ofType: "py")
    }

    /// True when this Mac can tag speakers: native helper + both models, or the
    /// dev venv + script + both models.
    var isDiarizationAvailable: Bool {
        Self.speakerTaggingIsAvailable(
            helper: URL(fileURLWithPath: speakerTaggingHelperPath),
            segmentationModel: URL(fileURLWithPath: diarizationSegModelPath),
            embeddingModel: URL(fileURLWithPath: diarizationEmbModelPath),
            scriptPath: diarizationScriptPath
        )
    }

    /// Pure availability check — injected paths and a FileManager so tests never
    /// need the real helper binaries or the developer's models folder.
    static func speakerTaggingIsAvailable(
        helper: URL,
        segmentationModel: URL,
        embeddingModel: URL,
        scriptPath: String?,
        fileManager: FileManager = .default
    ) -> Bool {
        guard fileManager.isExecutableFile(atPath: helper.path),
              fileManager.fileExists(atPath: segmentationModel.path),
              fileManager.fileExists(atPath: embeddingModel.path) else {
            return false
        }
        if isNativeSpeakerTaggingHelper(helper) { return true }
        return scriptPath != nil
    }

    static func isNativeSpeakerTaggingHelper(_ helper: URL) -> Bool {
        helper.lastPathComponent == "sherpa-onnx-offline-speaker-diarization"
    }

    // MARK: - Orchestration

    /// Called on the main thread from `stopRecording` when tagging is on.
    /// `samples` is the full recording, returned by the audio capture at stop.
    func beginDiarizationPass(samples: [Float]) {
        guard let logPath = currentLogPath else {
            log("Speaker tagging: no current log path")
            finishRecording(path: nil)
            return
        }

        guard isDiarizationAvailable else {
            log("Speaker tagging requested but tooling is missing")
            authError = "Speaker tagging isn't set up on this Mac yet, so the transcript was saved without speaker labels.\n\nThe speaker-tagging helper or its model data wasn't found."
            finishRecording(path: logPath)
            return
        }

        statusMessage = "Tagging speakers…"
        log("Speaker tagging: beginning pass with \(sessionSegments.count) segments, \(samples.count) audio samples")

        // Clear currentLogPath so any late live-chunk write can't clobber the
        // labeled transcript we produce.
        currentLogPath = nil

        // Hand off through the queues in order: transcribeQueue (serial, so this
        // runs after the final live chunk finishes and sessionSegments is
        // complete) -> diarizeQueue (the heavy speaker pass, kept off
        // transcribeQueue so a new recording isn't blocked).
        transcribeQueue.async {
            let segments = self.sessionSegments
            self.sessionSegments = []
            self.log("Speaker tagging: captured \(segments.count) segments from transcribeQueue")
            self.diarizeQueue.async {
                self.performDiarization(samples: samples, segments: segments, logPath: logPath)
                DispatchQueue.main.async { self.finishRecording(path: logPath) }
            }
        }
    }

    /// Runs entirely on `diarizeQueue`. Uses the timestamps captured live, so
    /// there is no second transcription pass — only speaker detection + merge.
    private func performDiarization(samples: [Float], segments: [TextSegment], logPath: URL) {
        guard !samples.isEmpty, !segments.isEmpty else {
            log("Speaker tagging: nothing to tag (no samples or segments)")
            return
        }

        log("Speaker tagging: starting diarization with \(samples.count) samples and \(segments.count) segments")

        let tmp = FileManager.default.temporaryDirectory
        let wavURL = tmp.appendingPathComponent("hover-session-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }

        do {
            try WAVFile.write(samples: samples, sampleRate: sampleRate, to: wavURL)
            log("Speaker tagging: WAV file written to \(wavURL.path)")
        } catch {
            log("Speaker tagging: WAV write failed — \(error.localizedDescription)")
            return
        }

        guard let turns = runSpeakerDiarizer(wavURL: wavURL) else {
            log("Speaker tagging: diarizer returned nil")
            return
        }

        guard !turns.isEmpty else {
            log("Speaker tagging: no speaker turns detected")
            return
        }

        log("Speaker tagging: detected \(turns.count) speaker turns, merging with segments")
        let body = Self.mergeSpeakers(segments: segments, turns: turns)
        guard body.rangeOfCharacter(from: .alphanumerics) != nil else {
            log("Speaker tagging: merged body is empty or has no alphanumerics")
            return
        }

        let title = logPath.deletingPathExtension().lastPathComponent
        transcriptStore.write(title: title, body: body, to: logPath)
        log("Speaker tagging: wrote labeled transcript to \(logPath.path) (\(turns.count) turns)")
    }

    // MARK: - sherpa-onnx diarizer

    /// Tuning shared with `Scripts/diarize.py` so the native helper and the
    /// Python path produce equivalent clustering.
    static let speakerTaggingClusterThreshold = 0.8
    static let speakerTaggingMinDurationOn = 0.5
    static let speakerTaggingMinDurationOff = 0.5

    /// CLI args for `sherpa-onnx-offline-speaker-diarization`, including today's
    /// threshold and minimum on/off durations.
    static func nativeSpeakerTaggingArguments(
        segmentationModel: String,
        embeddingModel: String,
        wavPath: String
    ) -> [String] {
        [
            "--clustering.cluster-threshold=\(speakerTaggingClusterThreshold)",
            "--min-duration-on=\(speakerTaggingMinDurationOn)",
            "--min-duration-off=\(speakerTaggingMinDurationOff)",
            "--segmentation.pyannote-model=\(segmentationModel)",
            "--embedding.model=\(embeddingModel)",
            wavPath,
        ]
    }

    private func runSpeakerDiarizer(wavURL: URL) -> [SpeakerTurn]? {
        let helper = URL(fileURLWithPath: speakerTaggingHelperPath)
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            log("Speaker tagging: helper not found at \(helper.path)")
            return nil
        }

        if Self.isNativeSpeakerTaggingHelper(helper) {
            return runNativeSpeakerDiarizer(helper: helper, wavURL: wavURL)
        }
        return runPythonSpeakerDiarizer(python: helper, wavURL: wavURL)
    }

    private func runNativeSpeakerDiarizer(helper: URL, wavURL: URL) -> [SpeakerTurn]? {
        let arguments = Self.nativeSpeakerTaggingArguments(
            segmentationModel: diarizationSegModelPath,
            embeddingModel: diarizationEmbModelPath,
            wavPath: wavURL.path
        )
        guard let stdout = runSpeakerTaggingProcess(
            executable: helper, arguments: arguments
        ) else {
            return nil
        }
        let turns = Self.parseNativeSpeakerTurns(stdout)
        if turns.isEmpty {
            log("Speaker tagging: native helper produced no parseable turns")
        }
        return turns
    }

    private func runPythonSpeakerDiarizer(python: URL, wavURL: URL) -> [SpeakerTurn]? {
        guard let script = diarizationScriptPath else {
            log("Speaker tagging: diarization script not found in bundle")
            return nil
        }

        let arguments = [
            script,
            "--seg-model", diarizationSegModelPath,
            "--emb-model", diarizationEmbModelPath,
            "--wav", wavURL.path,
        ]
        guard let stdout = runSpeakerTaggingProcess(
            executable: python, arguments: arguments
        ) else {
            return nil
        }
        guard let data = stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segs = obj["segments"] as? [[String: Any]] else {
            log("Speaker tagging: failed to parse diarizer JSON response: \(stdout)")
            return nil
        }

        return segs.compactMap { seg in
            guard let start = (seg["start"] as? NSNumber)?.doubleValue,
                  let end = (seg["end"] as? NSNumber)?.doubleValue,
                  let speaker = (seg["speaker"] as? NSNumber)?.intValue else { return nil }
            return SpeakerTurn(start: start, end: end, speaker: speaker)
        }
    }

    /// Spawn a helper, wait for exit, and return stdout on success.
    private func runSpeakerTaggingProcess(
        executable: URL,
        arguments: [String]
    ) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log("Speaker tagging: diarizer launch failed — \(error.localizedDescription)")
            return nil
        }

        guard process.terminationStatus == 0 else {
            let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: stderrData, encoding: .utf8) ?? "(no stderr)"
            log("Speaker tagging: diarizer exited with status \(process.terminationStatus). stderr: \(stderrText)")
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Native helper output

    /// Parse stdout from `sherpa-onnx-offline-speaker-diarization` into turns.
    ///
    /// The helper prints human lines like `0.000 -- 3.800 speaker_00`, plus
    /// config/progress noise. Non-matching lines are skipped so a partial or
    /// noisy dump still yields the turns that are present.
    static func parseNativeSpeakerTurns(_ output: String) -> [SpeakerTurn] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            parseNativeSpeakerTurnLine(String(line))
        }
    }

    private static func parseNativeSpeakerTurnLine(_ line: String) -> SpeakerTurn? {
        // `%.3f -- %.3f speaker_%02d` from OfflineSpeakerDiarizationSegment::ToString
        let pattern = #"^\s*([0-9]+(?:\.[0-9]+)?)\s+--\s+([0-9]+(?:\.[0-9]+)?)\s+speaker_(\d+)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges == 4,
              let startRange = Range(match.range(at: 1), in: line),
              let endRange = Range(match.range(at: 2), in: line),
              let speakerRange = Range(match.range(at: 3), in: line),
              let start = Double(line[startRange]),
              let end = Double(line[endRange]),
              let speaker = Int(line[speakerRange]) else {
            return nil
        }
        return SpeakerTurn(start: start, end: end, speaker: speaker)
    }

    // MARK: - Merge

    /// Attributes the transcript text to speakers, then groups consecutive text
    /// from the same speaker into paragraphs.
    static func mergeSpeakers(segments: [TextSegment], turns: [SpeakerTurn]) -> String {
        let ordered = turns.sorted { $0.start < $1.start }

        var paragraphs: [String] = []
        var currentSpeaker = Int.min
        var currentText = ""

        // Map raw cluster IDs to clean sequential labels (Speaker 1, 2, 3…) in
        // order of first appearance, so gaps in the clustering don't show up.
        var displayNumber: [Int: Int] = [:]
        func label(for raw: Int) -> String {
            guard raw >= 0 else { return "Unknown speaker" }
            if let n = displayNumber[raw] { return "Speaker \(n)" }
            let n = displayNumber.count + 1
            displayNumber[raw] = n
            return "Speaker \(n)"
        }

        func flush() {
            guard !currentText.isEmpty else { return }
            paragraphs.append("**\(label(for: currentSpeaker)):** \(currentText)")
        }

        for segment in segments {
            for piece in attribute(segment, to: ordered) {
                if piece.speaker == currentSpeaker {
                    currentText += " " + piece.text
                } else {
                    flush()
                    currentSpeaker = piece.speaker
                    currentText = piece.text
                }
            }
        }
        flush()

        return paragraphs.joined(separator: "\n\n")
    }

    /// Splits one segment's text across the speaker turns it spans.
    ///
    /// A chunk of audio runs up to ten seconds, so it regularly covers more than
    /// one speaker turn. There are no word-level timings to cut on — reusing the
    /// live transcription instead of re-running Whisper is the whole point — so
    /// the words are dealt out in proportion to how long each speaker holds the
    /// floor within the segment. The exact word a turn changes on is a guess, but
    /// it stops a quick exchange from collapsing under a single label.
    ///
    /// - Parameter turns: overlapping turns, in speaking order.
    private static func attribute(
        _ segment: TextSegment,
        to turns: [SpeakerTurn]
    ) -> [(speaker: Int, text: String)] {
        let text = segment.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return [] }

        // How long each speaker holds the floor inside this segment, in the order
        // they speak. Consecutive stretches by one speaker count as a single share.
        var shares: [(speaker: Int, seconds: Double)] = []
        for turn in turns {
            let overlap = min(segment.end, turn.end) - max(segment.start, turn.start)
            guard overlap > 0 else { continue }
            if shares.last?.speaker == turn.speaker {
                shares[shares.count - 1].seconds += overlap
            } else {
                shares.append((turn.speaker, overlap))
            }
        }

        // One speaker (or none, which reads as "Unknown speaker") takes it all.
        guard shares.count > 1 else { return [(shares.first?.speaker ?? -1, text)] }

        let words = text.split(separator: " ").map(String.init)
        let total = shares.reduce(0) { $0 + $1.seconds }
        var pieces: [(speaker: Int, text: String)] = []
        var wordIndex = 0
        var elapsed = 0.0

        for (index, share) in shares.enumerated() {
            elapsed += share.seconds
            // The last share takes whatever is left, so no word is dropped to
            // rounding.
            let end = index == shares.count - 1
                ? words.count
                : min(max(Int((elapsed / total * Double(words.count)).rounded()), wordIndex), words.count)
            guard end > wordIndex else { continue } // too brief to have earned a word
            pieces.append((share.speaker, words[wordIndex..<end].joined(separator: " ")))
            wordIndex = end
        }
        return pieces
    }
}

/// A timestamped piece of transcript text (seconds).
struct TextSegment {
    let start: Double
    let end: Double
    let text: String
}

/// A span of audio attributed to one speaker (seconds).
struct SpeakerTurn {
    let start: Double
    let end: Double
    let speaker: Int
}
