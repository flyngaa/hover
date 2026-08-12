import Foundation

public protocol SpeakerDiarizer: Sendable {
    var unavailableReason: String? { get }
    func diarize(samples: [Float], sampleRate: Int) async throws -> [SpeakerTurn]
}

public enum SpeakerDiarizationError: LocalizedError, Sendable {
    case wavWriteFailed(String)
    case processFailed(String)
    case malformedOutput

    public var errorDescription: String? {
        switch self {
        case .wavWriteFailed(let detail):
            return "Could not prepare audio for speaker tagging: \(detail)"
        case .processFailed(let detail):
            return "Speaker tagging failed: \(detail)"
        case .malformedOutput:
            return "Speaker tagging returned an unreadable result."
        }
    }
}
