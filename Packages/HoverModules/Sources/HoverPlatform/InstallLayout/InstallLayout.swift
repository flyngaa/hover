import Foundation
import HoverCore

/// Where the Whisper helper and the model data live on this Mac.
///
/// One place answers both, so the Transcriber never invents its own paths.
/// Resolution is **presence-based** from an injected bundle root and home
/// directory: the presence of `Contents/Helpers` selects the shipped layout,
/// while its absence selects the dev locations (Homebrew `whisper-cli`, the
/// transcripts `models/` folder). A shipped layout must contain the Whisper
/// helper or resolution fails immediately. Nothing branches on build flavour.
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

    /// Directory that holds model data (GGML). Never follows the Output
    /// Destination — transcripts and models stay separate concerns.
    public let modelsDirectory: URL

    /// Whether the expected Whisper model file is present under ``modelsDirectory``.
    public let ggmlModelPresent: Bool

    // MARK: - Model file paths

    public var ggmlModel: URL {
        modelsDirectory.appendingPathComponent(Self.ggmlModelFileName)
    }

    // MARK: - Well-known names

    public static let ggmlModelFileName = ModelArtifact.ggml.relativePath

    public static let homebrewWhisperHelper = "/opt/homebrew/bin/whisper-cli"

    private static let bundledWhisperRelativePath = "Contents/Helpers/whisper-cli"
    private static let bundledHelpersRelativePath = "Contents/Helpers"

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

        let hasBundledWhisper =
            regularFileExists(at: bundledWhisper, fileManager: fileManager)
            && fileManager.isExecutableFile(atPath: bundledWhisper.path)
        var helpersIsDirectory: ObjCBool = false
        let hasHelpersDirectory =
            fileManager.fileExists(
                atPath: bundledHelpers.path,
                isDirectory: &helpersIsDirectory
            ) && helpersIsDirectory.boolValue

        if hasHelpersDirectory && !hasBundledWhisper {
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

        return InstallLayout(
            whisperHelper: whisperHelper,
            modelsDirectory: modelsDirectory,
            ggmlModelPresent: modelFilePresent(
                named: ggmlModelFileName, under: modelsDirectory, fileManager: fileManager
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
