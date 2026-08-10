import Foundation

public protocol Transcriber: Sendable {
    func transcribe(samples: [Float]) async throws -> String
    var unavailableReason: String? { get }
}

public enum TranscriptionError: Error, LocalizedError {
    case processFailed(underlying: Error)
    case wavWriteFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .processFailed(let underlying):
            return "Whisper process failed: \(underlying.localizedDescription)"
        case .wavWriteFailed(let underlying):
            return "Could not write audio for transcription: \(underlying.localizedDescription)"
        }
    }
}
