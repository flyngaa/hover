import Foundation

/// Where the Whisper helper, the speaker-tagging helper, and the model data live
/// on this Mac.
///
/// One place answers all three, so the Transcriber and the speaker-tagging pass
/// never each invent their own paths. Resolution is **presence-based** from an
/// injected bundle root and home directory: a helper inside the app bundle and a
/// populated Application Support model directory win when they exist; otherwise
/// the dev locations (Homebrew `whisper-cli`, the transcripts `models/` folder,
/// `diar-venv`) are used. Release builds always ship the helpers, so they always
/// take the release path — nothing branches on build flavour.
///
/// Bundle root and home are injected so tests never touch the real Application
/// Support folder or the developer's home. Production uses ``current``.
struct InstallLayout: Equatable {

    /// Absolute path to `whisper-cli` (bundled helper, or Homebrew on the dev path).
    let whisperHelper: URL

    /// Absolute path to the speaker-tagging helper (bundled native binary, or
    /// `diar-venv`'s Python on the dev path).
    let speakerTaggingHelper: URL

    /// Directory that holds model data (GGML + ONNX). Never follows the Output
    /// Destination — transcripts and models stay separate concerns.
    let modelsDirectory: URL

    /// Whether each expected model file is present under ``modelsDirectory``.
    /// Reported per-file so a half-written directory is visible as gaps, not as
    /// an all-or-nothing miss.
    let ggmlModelPresent: Bool
    let segmentationModelPresent: Bool
    let embeddingModelPresent: Bool

    // MARK: - Model file paths

    var ggmlModel: URL {
        modelsDirectory.appendingPathComponent(Self.ggmlModelFileName)
    }

    var segmentationModel: URL {
        modelsDirectory.appendingPathComponent(Self.segmentationModelRelativePath)
    }

    var embeddingModel: URL {
        modelsDirectory.appendingPathComponent(Self.embeddingModelFileName)
    }

    // MARK: - Well-known names

    static let ggmlModelFileName = "ggml-large-v3-turbo-q5_0.bin"
    static let segmentationModelRelativePath =
        "sherpa-onnx-pyannote-segmentation-3-0/model.onnx"
    static let embeddingModelFileName = "nemo_en_titanet_small.onnx"

    static let homebrewWhisperHelper = "/opt/homebrew/bin/whisper-cli"
    static let diarizationVenvPython = "diar-venv/bin/python"

    private static let bundledWhisperRelativePath = "Contents/Helpers/whisper-cli"
    private static let bundledSpeakerTaggingRelativePath =
        "Contents/Helpers/sherpa-onnx-offline-speaker-diarization"

    // MARK: - Resolution

    /// Production layout for this process's bundle and the current user's home.
    static var current: InstallLayout {
        resolve(
            bundleRoot: Bundle.main.bundleURL,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    /// Resolve helpers and model-data locations from injected roots.
    static func resolve(
        bundleRoot: URL,
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) -> InstallLayout {
        let bundledWhisper = bundleRoot.appendingPathComponent(bundledWhisperRelativePath)
        let bundledSpeakerTagging = bundleRoot
            .appendingPathComponent(bundledSpeakerTaggingRelativePath)

        let hasBundledWhisper = fileManager.isExecutableFile(atPath: bundledWhisper.path)
        let hasBundledSpeakerTagging = fileManager.isExecutableFile(
            atPath: bundledSpeakerTagging.path
        )

        let appSupportModels = homeDirectory
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Hover")
            .appendingPathComponent("models")
        let transcriptsModels = homeDirectory
            .appendingPathComponent("Documents")
            .appendingPathComponent("Transcripts")
            .appendingPathComponent("models")

        let appSupportPopulated = modelFilePresent(
            named: ggmlModelFileName, under: appSupportModels, fileManager: fileManager
        ) || modelFilePresent(
            named: segmentationModelRelativePath, under: appSupportModels,
            fileManager: fileManager
        ) || modelFilePresent(
            named: embeddingModelFileName, under: appSupportModels, fileManager: fileManager
        )

        // Bundled helpers mean the release layout, including an (possibly still
        // empty) Application Support models directory that first-launch setup
        // will fill. A populated Application Support directory also wins on its
        // own, so reinstalling over existing model data keeps using it.
        let useReleaseModels = hasBundledWhisper || hasBundledSpeakerTagging
            || appSupportPopulated
        let modelsDirectory = useReleaseModels ? appSupportModels : transcriptsModels

        let whisperHelper = hasBundledWhisper
            ? bundledWhisper
            : URL(fileURLWithPath: homebrewWhisperHelper)

        let speakerTaggingHelper = hasBundledSpeakerTagging
            ? bundledSpeakerTagging
            : modelsDirectory.appendingPathComponent(diarizationVenvPython)

        return InstallLayout(
            whisperHelper: whisperHelper,
            speakerTaggingHelper: speakerTaggingHelper,
            modelsDirectory: modelsDirectory,
            ggmlModelPresent: modelFilePresent(
                named: ggmlModelFileName, under: modelsDirectory, fileManager: fileManager
            ),
            segmentationModelPresent: modelFilePresent(
                named: segmentationModelRelativePath, under: modelsDirectory,
                fileManager: fileManager
            ),
            embeddingModelPresent: modelFilePresent(
                named: embeddingModelFileName, under: modelsDirectory,
                fileManager: fileManager
            )
        )
    }

    private static func modelFilePresent(
        named relativePath: String,
        under directory: URL,
        fileManager: FileManager
    ) -> Bool {
        fileManager.fileExists(
            atPath: directory.appendingPathComponent(relativePath).path
        )
    }
}
