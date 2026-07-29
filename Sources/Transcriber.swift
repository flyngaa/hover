import Foundation
import AVFoundation

/// Turns captured audio samples into text.
///
/// The seam that lets the transcription pipeline be tested without a machine
/// that has `whisper-cli` installed: production uses ``WhisperCLITranscriber``,
/// tests supply a fake.
protocol Transcriber {
    /// Transcribe raw 16 kHz mono float samples.
    ///
    /// - Returns: cleaned text, or an empty string when there are no real words
    ///   (silence or a hallucinated fragment like a lone "." on quiet audio).
    /// - Throws: ``TranscriptionError`` when the transcription genuinely fails
    ///   (e.g. the whisper process couldn't run) — distinct from "no words".
    func transcribe(samples: [Float]) throws -> String
}

/// A genuine failure of the transcription process — not the same as "no words found".
enum TranscriptionError: Error, LocalizedError {
    /// The whisper process could not be launched.
    case processFailed(underlying: Error)
    /// Writing the temporary WAV the process reads from failed.
    case wavWriteFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .processFailed(let underlying):
            return "Whisper process failed: \(underlying.localizedDescription)"
        case .wavWriteFailed(let underlying):
            return "Could not write audio for transcription: \(underlying.localizedDescription)"
        }
    }
}

/// ``Transcriber`` backed by the whisper.cpp command-line tool.
///
/// Owns everything between "here are some samples" and "here is the text":
/// WAV-writing, spawning `whisper-cli`, cleaning its output, and dropping
/// silence / hallucinated fragments. All of its external tool locations and
/// tuning are injected, so a test can point it at a fake binary.
struct WhisperCLITranscriber: Transcriber {

    /// Absolute path to the `whisper-cli` executable.
    let whisperBinary: String
    /// Absolute path to the GGML model file.
    let modelPath: String
    /// Sample rate the samples were captured at (whisper expects 16 kHz).
    let sampleRate: Int
    /// Worker threads passed to whisper-cli.
    let threadCount: Int
    /// Below this RMS the whole chunk is treated as silence and skipped.
    let silenceRMSThreshold: Float
    /// Called with a short human-readable line for logging. Defaults to no-op.
    let log: (String) -> Void

    init(
        whisperBinary: String = TranscriberEngine.Config.whisperBinary,
        modelPath: String = TranscriberEngine.modelsDirectory
            .appendingPathComponent(TranscriberEngine.Config.modelFileName).path,
        sampleRate: Int = TranscriberEngine.Config.sampleRate,
        threadCount: Int = max(4, ProcessInfo.processInfo.activeProcessorCount - 2),
        silenceRMSThreshold: Float = TranscriberEngine.Config.silenceRMSThreshold,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.whisperBinary = whisperBinary
        self.modelPath = modelPath
        self.sampleRate = sampleRate
        self.threadCount = threadCount
        self.silenceRMSThreshold = silenceRMSThreshold
        self.log = log
    }

    func transcribe(samples: [Float]) throws -> String {
        // Don't spend a whisper run on near-silent audio.
        guard Self.rms(of: samples) >= silenceRMSThreshold / 2 else {
            log("Skipped silent chunk (\(String(format: "%.1f", Double(samples.count) / Double(sampleRate)))s)")
            return ""
        }

        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hover-chunk-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }

        do {
            try WAVFile.write(samples: samples, sampleRate: sampleRate, to: wavURL)
        } catch {
            throw TranscriptionError.wavWriteFailed(underlying: error)
        }

        let raw = try runWhisper(on: wavURL)
        let cleaned = Self.cleanWhisperOutput(raw)

        // Whisper occasionally hallucinates a lone "." or "," on near-silent
        // audio — treat anything with no actual words as "no words".
        guard cleaned.rangeOfCharacter(from: .alphanumerics) != nil else { return "" }
        return cleaned
    }

    // MARK: - Internals

    /// Runs whisper-cli on a WAV file and returns its raw stdout.
    private func runWhisper(on wavURL: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperBinary)
        process.arguments = [
            "-m", modelPath,
            "-f", wavURL.path,
            "--no-timestamps",
            "--language", "auto",
            "--threads", "\(threadCount)",
            "--no-prints",
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            let start = Date()
            try process.run()
            process.waitUntilExit()
            let text = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
            log("Whisper chunk done in \(elapsed)s: \(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))")
            return text
        } catch {
            log("Whisper failed: \(error.localizedDescription)")
            throw TranscriptionError.processFailed(underlying: error)
        }
    }

    /// Strips whisper's bracketed/parenthesised annotations and collapses lines.
    static func cleanWhisperOutput(_ raw: String) -> String {
        var text = raw
        for pattern in ["\\[[^\\]]*\\]", "\\([^\\)]*\\)"] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Root-mean-square amplitude — a cheap proxy for loudness/silence.
    static func rms<S: Sequence>(of samples: S) -> Float where S.Element == Float {
        var sum: Float = 0
        var count = 0
        for sample in samples {
            sum += sample * sample
            count += 1
        }
        return (sum / Float(max(count, 1))).squareRoot()
    }
}
