import Foundation

/// How loud a stretch of audio samples is — the basis of every "is this silence?"
/// decision in the app.
///
/// Shared because two independent decisions need the same measurement: where the
/// ``Chunker`` cuts a chunk (on a quiet tail), and whether
/// ``WhisperCLITranscriber`` spends a whisper run on a chunk at all. It lived in
/// both places, identically, until they were merged here.
public enum AudioLevel {

    /// Root-mean-square amplitude — a cheap proxy for loudness/silence.
    /// Empty input is silent rather than undefined.
    public static func rms<S: Sequence>(of samples: S) -> Float where S.Element == Float {
        var sum: Float = 0
        var count = 0
        for sample in samples {
            sum += sample * sample
            count += 1
        }
        return (sum / Float(max(count, 1))).squareRoot()
    }
}
