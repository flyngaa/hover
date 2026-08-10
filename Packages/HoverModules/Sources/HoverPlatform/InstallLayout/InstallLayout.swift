import Foundation
import HoverCore

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
public struct InstallLayout: Equatable, Sendable {

    public enum ResolutionError: LocalizedError, Equatable, Sendable {
        case incompleteShippedHelpers

        public var errorDescription: String? {
            switch self {
            case .incompleteShippedHelpers:
                return "Hover's shipped helpers are incomplete. Reinstall Hover."
            }
        }
    }

    /// Absolute path to `whisper-cli` (bundled helper, or Homebrew on the dev path).
    public let whisperHelper: URL

    /// Absolute path to the speaker-tagging helper (bundled native binary, or
    /// `diar-venv`'s Python on the dev path).
    public let speakerTaggingHelper: URL

    /// Directory that holds model data (GGML + ONNX). Never follows the Output
    /// Destination — transcripts and models stay separate concerns.
    public let modelsDirectory: URL

    /// Whether each expected model file is present under ``modelsDirectory``.
    /// Reported per-file so a half-written directory is visible as gaps, not as
    /// an all-or-nothing miss.
    public let ggmlModelPresent: Bool
    public let segmentationModelPresent: Bool
    public let embeddingModelPresent: Bool

    // MARK: - Model file paths

    public var ggmlModel: URL {
        modelsDirectory.appendingPathComponent(Self.ggmlModelFileName)
    }

    public var segmentationModel: URL {
        modelsDirectory.appendingPathComponent(Self.segmentationModelRelativePath)
    }

    public var embeddingModel: URL {
        modelsDirectory.appendingPathComponent(Self.embeddingModelFileName)
    }

    // MARK: - Well-known names

    public static let ggmlModelFileName = ModelArtifact.ggml.relativePath
    public static let segmentationModelRelativePath = ModelArtifact.segmentation.relativePath
    public static let embeddingModelFileName = ModelArtifact.embedding.relativePath

    public static let homebrewWhisperHelper = "/opt/homebrew/bin/whisper-cli"
    public static let diarizationVenvPython = "diar-venv/bin/python"

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
    public static var current: InstallLayout {
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
    public static func resolve(
        bundleRoot: URL,
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> InstallLayout {
        let bundledHelpers = bundleRoot.appendingPathComponent(bundledHelpersRelativePath)
        let bundledWhisper = bundleRoot.appendingPathComponent(bundledWhisperRelativePath)
        let bundledSpeakerTagging =
            bundleRoot
            .appendingPathComponent(bundledSpeakerTaggingRelativePath)

        let hasBundledWhisper =
            regularFileExists(at: bundledWhisper, fileManager: fileManager)
            && fileManager.isExecutableFile(atPath: bundledWhisper.path)
        let hasBundledSpeakerTagging =
            regularFileExists(
                at: bundledSpeakerTagging,
                fileManager: fileManager
            ) && fileManager.isExecutableFile(atPath: bundledSpeakerTagging.path)
        var helpersIsDirectory: ObjCBool = false
        let hasHelpersDirectory =
            fileManager.fileExists(
                atPath: bundledHelpers.path,
                isDirectory: &helpersIsDirectory
            ) && helpersIsDirectory.boolValue
        let hasONNXRuntime = bundledONNXRuntimeDirectories.contains { directory in
            regularFileExists(
                at:
                    bundleRoot
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

        let appSupportModels =
            homeDirectory
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Hover")
            .appendingPathComponent("models")
        let transcriptsModels =
            homeDirectory
            .appendingPathComponent("Documents")
            .appendingPathComponent("Transcripts")
            .appendingPathComponent("models")

        // The Helpers directory is the sole ship signal. Existing Application
        // Support model data must not pull a dev build onto the shipped layout.
        let modelsDirectory = hasHelpersDirectory ? appSupportModels : transcriptsModels

        let whisperHelper =
            hasBundledWhisper
            ? bundledWhisper
            : URL(fileURLWithPath: homebrewWhisperHelper)

        let speakerTaggingHelper =
            hasBundledSpeakerTagging
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
