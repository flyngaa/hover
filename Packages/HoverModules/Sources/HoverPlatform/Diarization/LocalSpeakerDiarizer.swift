import Foundation
import HoverCore

public struct LocalSpeakerDiarizer: SpeakerDiarizer {
    private let layout: InstallLayout
    private let scriptPath: String?
    private let processRunner: any ProcessRunning

    public init(
        layout: InstallLayout,
        scriptPath: String? = Bundle.main.path(forResource: "diarize", ofType: "py"),
        processRunner: any ProcessRunning = AsyncProcessRunner()
    ) {
        self.layout = layout
        self.scriptPath = scriptPath
        self.processRunner = processRunner
    }

    public var unavailableReason: String? {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: layout.speakerTaggingHelper.path),
            fileManager.fileExists(atPath: layout.segmentationModel.path),
            fileManager.fileExists(atPath: layout.embeddingModel.path)
        else {
            return "The speaker-tagging helper or its model data wasn't found."
        }
        if !Self.isNativeHelper(layout.speakerTaggingHelper), scriptPath == nil {
            return "The speaker-tagging script wasn't found."
        }
        return nil
    }

    public func diarize(samples: [Float], sampleRate: Int) async throws -> [SpeakerTurn] {
        HoverLog.beginDiarization()
        defer { HoverLog.endDiarization() }
        if let unavailableReason {
            throw SpeakerDiarizationError.processFailed(unavailableReason)
        }
        guard !samples.isEmpty else { return [] }

        let fileManager = FileManager.default
        let wavURL = fileManager.temporaryDirectory
            .appendingPathComponent("hover-session-\(UUID().uuidString).wav")
        defer { try? fileManager.removeItem(at: wavURL) }
        do {
            try WAVFile.write(samples: samples, sampleRate: sampleRate, to: wavURL)
        } catch {
            throw SpeakerDiarizationError.wavWriteFailed(error.localizedDescription)
        }

        let native = Self.isNativeHelper(layout.speakerTaggingHelper)
        let arguments: [String]
        if native {
            arguments = Self.nativeArguments(
                segmentationModel: layout.segmentationModel.path,
                embeddingModel: layout.embeddingModel.path,
                wavPath: wavURL.path
            )
        } else {
            guard let scriptPath else {
                throw SpeakerDiarizationError.processFailed("The diarization script is missing.")
            }
            arguments = [
                scriptPath,
                "--seg-model", layout.segmentationModel.path,
                "--emb-model", layout.embeddingModel.path,
                "--wav", wavURL.path,
            ]
        }

        let result = try await processRunner.run(
            executable: layout.speakerTaggingHelper,
            arguments: arguments
        )
        guard result.terminationStatus == 0 else {
            throw SpeakerDiarizationError.processFailed(result.standardError)
        }
        let turns =
            native
            ? DiarizationOutputParser.nativeTurns(result.standardOutput)
            : DiarizationOutputParser.pythonTurns(result.standardOutput)
        guard let turns else { throw SpeakerDiarizationError.malformedOutput }
        return turns
    }

    public static func isNativeHelper(_ helper: URL) -> Bool {
        helper.lastPathComponent == "sherpa-onnx-offline-speaker-diarization"
    }

    public static func isAvailable(
        helper: URL,
        segmentationModel: URL,
        embeddingModel: URL,
        scriptPath: String?,
        fileManager: FileManager = .default
    ) -> Bool {
        guard fileManager.isExecutableFile(atPath: helper.path),
            fileManager.fileExists(atPath: segmentationModel.path),
            fileManager.fileExists(atPath: embeddingModel.path)
        else { return false }
        return isNativeHelper(helper) || scriptPath != nil
    }

    public static func nativeArguments(
        segmentationModel: String,
        embeddingModel: String,
        wavPath: String
    ) -> [String] {
        [
            "--clustering.cluster-threshold=0.8",
            "--min-duration-on=0.5",
            "--min-duration-off=0.5",
            "--segmentation.pyannote-model=\(segmentationModel)",
            "--embedding.model=\(embeddingModel)",
            wavPath,
        ]
    }
}
