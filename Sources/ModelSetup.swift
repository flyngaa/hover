import Foundation

/// Whether first-launch model setup is needed, in progress, or failed.
///
/// The state the UI needs — the setup screen replaces the normal window content
/// while this is anything other than ``notNeeded``.
enum ModelSetupStatus: Equatable {
    /// All three model files are present and size-checked; no setup screen.
    case notNeeded
    /// Fetching missing model data. `fraction` is overall progress in `0...1`.
    case running(fraction: Double)
    /// The last fetch failed. `message` is a plain sentence for the user.
    case failed(message: String)
}

/// Reports which model data is present and fetches what is missing.
///
/// A seam alongside Transcriber, Audio Capture, Transcript Store, Vault Finder,
/// and Settings Store: production downloads from pinned upstream URLs into the
/// model directory; tests supply a fake. Progress is overall (one fraction),
/// never per-file.
///
/// _Avoid_: installer, downloader, bootstrapper.
protocol ModelSetup: AnyObject {
    /// `true` when all three required model files are present and size-checked.
    var isComplete: Bool { get }

    /// Fetch any files that are still missing (or fail the size check).
    ///
    /// Calls `progress` with an overall fraction in `0...1`. Already-present
    /// files are skipped so Retry after a partial failure doesn't start over.
    func fetchMissing(progress: @escaping @Sendable (Double) -> Void) async throws
}

/// The three model-data artifacts first-launch setup must place under the
/// models directory. Sizes are the pinned upstream byte lengths; a mismatch
/// counts as missing.
enum ModelArtifact: CaseIterable {
    case ggml
    case segmentation
    case embedding

    var relativePath: String {
        switch self {
        case .ggml:
            return InstallLayout.ggmlModelFileName
        case .segmentation:
            return InstallLayout.segmentationModelRelativePath
        case .embedding:
            return InstallLayout.embeddingModelFileName
        }
    }

    var expectedSize: Int64 {
        switch self {
        case .ggml: return 574_041_195
        case .segmentation: return 5_992_913
        case .embedding: return 40_257_283
        }
    }

    /// Total expected bytes across all three artifacts (~600 MB).
    static var totalExpectedSize: Int64 {
        allCases.reduce(0) { $0 + $1.expectedSize }
    }
}
