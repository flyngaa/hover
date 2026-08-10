import AVFoundation
import Foundation
import HoverCore

/// ``Transcriber`` backed by the whisper.cpp command-line tool.
///
/// Owns everything between "here are some samples" and "here is the text", and
/// everything about whisper itself: whether the binary and model are installed,
/// WAV-writing, spawning `whisper-cli`, cleaning its output, and dropping silence
/// / hallucinated fragments. Paths come from ``InstallLayout`` so the release and
/// dev locations stay in one place — nothing outside this file needs to know
/// whisper exists.
public struct WhisperCLITranscriber: Transcriber {

    /// Leave a couple of cores for the live audio capture, which must not stutter.
    private static var threadCount: Int {
        max(4, ProcessInfo.processInfo.activeProcessorCount - 2)
    }

    /// Whisper expects 16 kHz mono audio.
    private let sampleRate = RecordingConfiguration.default.sampleRate

    /// Below half this RMS the whole chunk is treated as silence and skipped.
    private let silenceRMSThreshold = RecordingConfiguration.default.silenceRMSThreshold

    /// Resolved helper and model-data locations. Injected so tests can supply a
    /// layout without reading the real home or Application Support.
    private let layout: InstallLayout

    /// Called with a short human-readable line for logging. Defaults to no-op.
    public let log: @Sendable (String) -> Void
    private let processRunner: any ProcessRunning

    public init(
        layout: InstallLayout = .current,
        processRunner: any ProcessRunning = AsyncProcessRunner(),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.layout = layout
        self.processRunner = processRunner
        self.log = log
    }

    public var unavailableReason: String? {
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

    public func transcribe(samples: [Float]) async throws -> String {
        // Don't spend a whisper run on near-silent audio.
        guard AudioLevel.rms(of: samples) >= silenceRMSThreshold / 2 else {
            log(
                "Skipped silent chunk (\(String(format: "%.1f", Double(samples.count) / Double(sampleRate)))s)"
            )
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

        let raw = try await runWhisper(on: wavURL)
        let cleaned = Self.cleanWhisperOutput(raw)

        // Whisper occasionally hallucinates a lone "." or "," on near-silent
        // audio — treat anything with no actual words as "no words".
        guard cleaned.rangeOfCharacter(from: .alphanumerics) != nil else { return "" }
        return cleaned
    }

    // MARK: - Internals

    /// Runs whisper-cli on a WAV file and returns its raw stdout.
    private func runWhisper(on wavURL: URL) async throws -> String {
        HoverLog.beginWhisperChunk()
        defer { HoverLog.endWhisperChunk() }
        let arguments = [
            "-m", layout.ggmlModel.path,
            "-f", wavURL.path,
            "--no-timestamps",
            "--language", "auto",
            "--threads", "\(Self.threadCount)",
            "--no-prints",
        ]
        do {
            let start = Date()
            let result = try await processRunner.run(
                executable: layout.whisperHelper,
                arguments: arguments
            )
            guard result.terminationStatus == 0 else {
                throw NSError(
                    domain: "Hover.Whisper",
                    code: Int(result.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: result.standardError]
                )
            }
            let text = result.standardOutput
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
            log("Whisper chunk done in \(elapsed)s")
            return text
        } catch {
            log("Whisper failed: \(error.localizedDescription)")
            throw TranscriptionError.processFailed(underlying: error)
        }
    }

    /// Strips whisper's bracketed/parenthesised annotations and collapses lines.
    public static func cleanWhisperOutput(_ raw: String) -> String {
        var text = raw
        for pattern in ["\\[[^\\]]*\\]", "\\([^\\)]*\\)"] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return
            text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
