import Foundation

/// Where the Whisper helper, the speaker-tagging helper, and the model data live
/// on this Mac.
///
/// One place answers all three, so the Transcriber and the speaker-tagging pass
/// never each invent their own paths. Resolution is **presence-based** from an
/// injected bundle root and home directory: the presence of `Contents/Helpers`
/// selects the shipped layout, while its absence selects the dev locations
/// (Homebrew `whisper-cli`, the transcripts `models/` folder, `diar-venv`). A
/// shipped layout must contain every helper or resolution fails immediately.
/// Nothing branches on build flavour.
///
/// Bundle root and home are injected so tests never touch the real Application
/// Support folder or the developer's home. Production uses ``current``.
struct InstallLayout: Equatable {

    enum ResolutionError: LocalizedError, Equatable {
        case incompleteShippedHelpers

        var errorDescription: String? {
            switch self {
            case .incompleteShippedHelpers:
                return "Hover's shipped helpers are incomplete. Reinstall Hover."
            }
        }
    }

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
    private static let bundledHelpersRelativePath = "Contents/Helpers"
    private static let bundledONNXRuntimeFileName = "libonnxruntime.1.27.0.dylib"
    private static let bundledONNXRuntimeDirectories = [
        "Contents/Frameworks",
        "Contents/Helpers",
    ]

    // MARK: - Resolution

    /// Production layout for this process's bundle and the current user's home.
    static var current: InstallLayout {
        do {
            return try resolve(
                bundleRoot: Bundle.main.bundleURL,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            )
        } catch {
            fatalError(error.localizedDescription)
        }
    }

    /// Resolve helpers and model-data locations from injected roots.
    static func resolve(
        bundleRoot: URL,
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> InstallLayout {
        let bundledHelpers = bundleRoot.appendingPathComponent(bundledHelpersRelativePath)
        let bundledWhisper = bundleRoot.appendingPathComponent(bundledWhisperRelativePath)
        let bundledSpeakerTagging = bundleRoot
            .appendingPathComponent(bundledSpeakerTaggingRelativePath)

        let hasBundledWhisper = regularFileExists(at: bundledWhisper, fileManager: fileManager)
            && fileManager.isExecutableFile(atPath: bundledWhisper.path)
        let hasBundledSpeakerTagging = regularFileExists(
            at: bundledSpeakerTagging,
            fileManager: fileManager
        ) && fileManager.isExecutableFile(atPath: bundledSpeakerTagging.path)
        var helpersIsDirectory: ObjCBool = false
        let hasHelpersDirectory = fileManager.fileExists(
            atPath: bundledHelpers.path,
            isDirectory: &helpersIsDirectory
        ) && helpersIsDirectory.boolValue
        let hasONNXRuntime = bundledONNXRuntimeDirectories.contains { directory in
            regularFileExists(
                at: bundleRoot
                    .appendingPathComponent(directory)
                    .appendingPathComponent(bundledONNXRuntimeFileName),
                fileManager: fileManager
            )
        }

        if hasHelpersDirectory
            && !(hasBundledWhisper && hasBundledSpeakerTagging && hasONNXRuntime)
        {
            throw ResolutionError.incompleteShippedHelpers
        }

        let appSupportModels = homeDirectory
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Hover")
            .appendingPathComponent("models")
        let transcriptsModels = homeDirectory
            .appendingPathComponent("Documents")
            .appendingPathComponent("Transcripts")
            .appendingPathComponent("models")

        // The Helpers directory is the sole ship signal. Existing Application
        // Support model data must not pull a dev build onto the shipped layout.
        let modelsDirectory = hasHelpersDirectory ? appSupportModels : transcriptsModels

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

    private static func regularFileExists(at url: URL, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return false
        }
        return attributes[.type] as? FileAttributeType == .typeRegular
    }
}
