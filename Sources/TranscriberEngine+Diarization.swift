import Foundation

/// Speaker tagging ("who spoke when"). After a recording stops, the full audio
/// is analyzed for speaker turns (sherpa-onnx, run via a bundled Python
/// helper) and merged with the timestamped text already captured during live
/// transcription — there is no second Whisper pass. The result is a
/// "Speaker 1: … / Speaker 2: …" transcript. Everything runs locally.
extension TranscriberEngine {

    // MARK: - Tooling locations

    var diarizationPython: String {
        Self.modelsDirectory.appendingPathComponent(Config.diarizationVenvPython).path
    }
    var diarizationSegModelPath: String {
        Self.modelsDirectory.appendingPathComponent(Config.diarizationSegModel).path
    }
    var diarizationEmbModelPath: String {
        Self.modelsDirectory.appendingPathComponent(Config.diarizationEmbModel).path
    }
    var diarizationScriptPath: String? {
        Bundle.main.path(forResource: "diarize", ofType: "py")
    }

    /// True only when the venv, both models, and the helper script are present.
    var isDiarizationAvailable: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: diarizationPython)
            && fm.fileExists(atPath: diarizationSegModelPath)
            && fm.fileExists(atPath: diarizationEmbModelPath)
            && diarizationScriptPath != nil
    }

    // MARK: - Orchestration

    /// Called on the main thread from `stopRecording` when tagging is on.
    /// `samples` is the full recording, returned by the audio capture at stop.
    func beginDiarizationPass(samples: [Float]) {
        guard let logPath = currentLogPath else {
            finishRecording(path: nil)
            return
        }

        guard isDiarizationAvailable else {
            log("Speaker tagging requested but tooling is missing")
            authError = "Speaker tagging isn't set up on this Mac yet, so the transcript was saved without speaker labels.\n\nThe local speaker-tagging models or their Python environment weren't found in the models folder."
            finishRecording(path: logPath)
            return
        }

        statusMessage = "Tagging speakers…"

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
            log("Speaker tagging: nothing to tag")
            return
        }

        let tmp = FileManager.default.temporaryDirectory
        let wavURL = tmp.appendingPathComponent("hover-session-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }

        do {
            try WAVFile.write(samples: samples, sampleRate: sampleRate, to: wavURL)
        } catch {
            log("Speaker tagging: WAV write failed — \(error.localizedDescription)")
            return
        }

        guard let turns = runSpeakerDiarizer(wavURL: wavURL), !turns.isEmpty else {
            log("Speaker tagging: no speaker turns detected")
            return
        }

        let body = Self.mergeSpeakers(segments: segments, turns: turns)
        guard body.rangeOfCharacter(from: .alphanumerics) != nil else { return }

        let title = logPath.deletingPathExtension().lastPathComponent
        transcriptStore.write(title: title, body: body, to: logPath)
        log("Speaker tagging: wrote labeled transcript (\(turns.count) turns)")
    }

    // MARK: - sherpa-onnx diarizer (via Python helper)

    private func runSpeakerDiarizer(wavURL: URL) -> [SpeakerTurn]? {
        guard let script = diarizationScriptPath else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: diarizationPython)
        process.arguments = [
            script,
            "--seg-model", diarizationSegModelPath,
            "--emb-model", diarizationEmbModelPath,
            "--wav", wavURL.path,
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log("Speaker tagging: diarizer launch failed — \(error.localizedDescription)")
            return nil
        }
        guard process.terminationStatus == 0 else {
            log("Speaker tagging: diarizer exited with \(process.terminationStatus)")
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segs = obj["segments"] as? [[String: Any]] else {
            return nil
        }

        return segs.compactMap { seg in
            guard let start = (seg["start"] as? NSNumber)?.doubleValue,
                  let end = (seg["end"] as? NSNumber)?.doubleValue,
                  let speaker = (seg["speaker"] as? NSNumber)?.intValue else { return nil }
            return SpeakerTurn(start: start, end: end, speaker: speaker)
        }
    }

    // MARK: - Merge

    /// Assigns each text segment to the speaker whose turn overlaps it most,
    /// then groups consecutive segments from the same speaker into paragraphs.
    static func mergeSpeakers(segments: [TextSegment], turns: [SpeakerTurn]) -> String {
        func speaker(for segment: TextSegment) -> Int {
            var best = -1
            var bestOverlap = 0.0
            for turn in turns {
                let overlap = min(segment.end, turn.end) - max(segment.start, turn.start)
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    best = turn.speaker
                }
            }
            return best
        }

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
            let text = segment.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let sp = speaker(for: segment)
            if sp == currentSpeaker {
                currentText += " " + text
            } else {
                flush()
                currentSpeaker = sp
                currentText = text
            }
        }
        flush()

        return paragraphs.joined(separator: "\n\n")
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
