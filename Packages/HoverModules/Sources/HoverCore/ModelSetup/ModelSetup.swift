import Foundation

/// Whether first-launch model setup is needed, in progress, or failed.
///
/// The state the UI needs — the setup screen replaces the normal window content
/// while this is anything other than ``notNeeded``.
public enum ModelSetupStatus: Equatable, Sendable {
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
@MainActor
public protocol ModelSetup: AnyObject {
    /// `true` when all three required model files are present and size-checked.
    var isComplete: Bool { get }

    /// Fetch missing files and stream overall progress in `0...1`.
    func fetchMissing() -> AsyncThrowingStream<Double, Error>
}

/// The three model-data artifacts first-launch setup must place under the
/// models directory. Sizes are the pinned upstream byte lengths; a mismatch
/// counts as missing.
public enum ModelArtifact: CaseIterable, Sendable {
    case ggml
    case segmentation
    case embedding

    public var relativePath: String {
        switch self {
        case .ggml:
            return "ggml-large-v3-turbo-q5_0.bin"
        case .segmentation:
            return "sherpa-onnx-pyannote-segmentation-3-0/model.onnx"
        case .embedding:
            return "nemo_en_titanet_small.onnx"
        }
    }

    public var expectedSize: Int64 {
        switch self {
        case .ggml: return 574_041_195
        case .segmentation: return 5_992_913
        case .embedding: return 40_257_283
        }
    }

    /// Total expected bytes across all three artifacts (~600 MB).
    public static var totalExpectedSize: Int64 {
        allCases.reduce(0) { $0 + $1.expectedSize }
    }

    public static let segmentationArchiveSize: Int64 = 6_958_444

    public var sourceURL: URL {
        switch self {
        case .ggml:
            return URL(
                string:
                    "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin"
            )!
        case .segmentation:
            return URL(
                string:
                    "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2"
            )!
        case .embedding:
            return URL(
                string:
                    "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/nemo_en_titanet_small.onnx"
            )!
        }
    }
}
