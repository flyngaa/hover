import Foundation

/// Whether first-launch model setup is needed, in progress, or failed.
///
/// The state the UI needs — the setup screen replaces the normal window content
/// while this is anything other than ``notNeeded``.
public enum ModelSetupStatus: Equatable, Sendable {
    /// The Whisper model file is present and size-checked; no setup screen.
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
@MainActor
public protocol ModelSetup: AnyObject {
    /// `true` when the required Whisper model file is present and size-checked.
    var isComplete: Bool { get }

    /// Fetch missing files and stream overall progress in `0...1`.
    func fetchMissing() -> AsyncThrowingStream<Double, Error>
}

/// Model-data artifacts first-launch setup must place under the models
/// directory. Sizes are the pinned upstream byte lengths; a mismatch counts as
/// missing.
public enum ModelArtifact: CaseIterable, Sendable {
    case ggml

    public var relativePath: String {
        switch self {
        case .ggml:
            return "ggml-large-v3-turbo-q5_0.bin"
        }
    }

    public var expectedSize: Int64 {
        switch self {
        case .ggml: return 574_041_195
        }
    }

    /// Total expected bytes across all artifacts (~575 MB).
    public static var totalExpectedSize: Int64 {
        allCases.reduce(0) { $0 + $1.expectedSize }
    }

    public var sourceURL: URL {
        switch self {
        case .ggml:
            return URL(
                string:
                    "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin"
            )!
        }
    }
}
