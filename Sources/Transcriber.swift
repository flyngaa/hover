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

    /// `nil` when transcription can actually run; otherwise a sentence the user
    /// can act on, checked before a recording starts so nobody talks for ten
    /// minutes into a tool that was never going to work.
    ///
    /// Asking the transcriber keeps knowledge of external tools and models on the
    /// one side of this seam that installs them — the engine used to keep its own
    /// copy of the paths and check those instead, which could disagree.
    var unavailableReason: String? { get }
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
/// Owns everything between "here are some samples" and "here is the text", and
/// everything about whisper itself: whether the binary and model are installed,
/// WAV-writing, spawning `whisper-cli`, cleaning its output, and dropping silence
/// / hallucinated fragments. Paths come from ``InstallLayout`` so the release and
/// dev locations stay in one place — nothing outside this file needs to know
/// whisper exists.
struct WhisperCLITranscriber: Transcriber {

    /// Leave a couple of cores for the live audio capture, which must not stutter.
    private static var threadCount: Int {
        max(4, ProcessInfo.processInfo.activeProcessorCount - 2)
    }

    /// Whisper expects 16 kHz mono audio.
    private let sampleRate = TranscriberEngine.Config.sampleRate

    /// Below half this RMS the whole chunk is treated as silence and skipped.
    private let silenceRMSThreshold = TranscriberEngine.Config.silenceRMSThreshold

    /// Resolved helper and model-data locations. Injected so tests can supply a
    /// layout without reading the real home or Application Support.
    private let layout: InstallLayout

    /// Called with a short human-readable line for logging. Defaults to no-op.
    let log: (String) -> Void

    init(
        layout: InstallLayout = .current,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.layout = layout
        self.log = log
    }

    var unavailableReason: String? {
        let binary = layout.whisperHelper.path
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            if binary == InstallLayout.homebrewWhisperHelper {
                return "whisper-cli not found at \(binary).\nInstall with: brew install whisper-cpp"
            }
            return "whisper-cli not found at \(binary)."
        }
        let modelPath = layout.ggmlModel.path
        guard FileManager.default.fileExists(atPath: modelPath) else {
            return "Whisper model not found at:\n\(modelPath)\n\nDownload may still be in progress."
        }
        return nil
    }

    func transcribe(samples: [Float]) throws -> String {
        // Don't spend a whisper run on near-silent audio.
        guard AudioLevel.rms(of: samples) >= silenceRMSThreshold / 2 else {
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
        process.executableURL = layout.whisperHelper
        process.arguments = [
            "-m", layout.ggmlModel.path,
            "-f", wavURL.path,
            "--no-timestamps",
            "--language", "auto",
            "--threads", "\(Self.threadCount)",
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
}
