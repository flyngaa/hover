import Foundation

public struct TranscriptLibrary: Sendable {
    public let transcripts: [SavedTranscript]
    public let groups: [String]

    public init(transcripts: [SavedTranscript], groups: [String]) {
        self.transcripts = transcripts
        self.groups = groups
    }
}

public enum TranscriptStoreError: Error, LocalizedError, Sendable, Equatable {
    case invalidName
    case destinationExists
    case unreadableDirectory(diagnostic: String)
    case createDirectoryFailed(diagnostic: String)
    case readFailed(diagnostic: String)
    case writeFailed(diagnostic: String)
    case renameFailed(diagnostic: String)
    case moveFailed(diagnostic: String)
    case deleteFailed(diagnostic: String)
    case noAvailableDestination

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            "Enter a non-empty transcript name."
        case .destinationExists:
            "A transcript with that name already exists."
        case .unreadableDirectory:
            "Hover couldn't read the transcript folder."
        case .createDirectoryFailed:
            "Hover couldn't create the selected transcript folder."
        case .readFailed:
            "Hover couldn't read the transcript."
        case .writeFailed:
            "Hover couldn't save the transcript."
        case .renameFailed:
            "Hover couldn't rename the transcript."
        case .moveFailed:
            "Hover couldn't move the transcript."
        case .deleteFailed:
            "Hover couldn't delete the transcript."
        case .noAvailableDestination:
            "Hover couldn't find an available filename for the transcript."
        }
    }
}

public struct TranscriptRelocationFailure: Sendable, Equatable {
    public let transcript: SavedTranscript
    public let error: TranscriptStoreError

    public init(transcript: SavedTranscript, error: TranscriptStoreError) {
        self.transcript = transcript
        self.error = error
    }
}

public struct TranscriptRelocationReport: Sendable, Equatable {
    public let moved: [SavedTranscript]
    public let unchanged: [SavedTranscript]
    public let failures: [TranscriptRelocationFailure]

    public init(
        moved: [SavedTranscript] = [],
        unchanged: [SavedTranscript] = [],
        failures: [TranscriptRelocationFailure] = []
    ) {
        self.moved = moved
        self.unchanged = unchanged
        self.failures = failures
    }
}

public protocol TranscriptStore: Sendable {
    func availableRecordingDestination(for date: Date, in directory: URL) -> (
        title: String, url: URL
    )
    func load(in directory: URL) throws -> TranscriptLibrary
    func rename(_ transcript: SavedTranscript, to newName: String) throws -> SavedTranscript
    func move(_ transcript: SavedTranscript, toGroup group: String?, in directory: URL) throws
        -> SavedTranscript
    func relocate(_ transcripts: [SavedTranscript], to directory: URL) -> TranscriptRelocationReport
    func delete(_ transcript: SavedTranscript) throws
    func matches(_ transcript: SavedTranscript, query: String) -> Bool
    func content(of transcript: SavedTranscript) throws -> String
    func write(title: String, body: String, to url: URL) throws
    func discardDraft(at url: URL)
}

extension TranscriptStore {
    public func discardDraft(at url: URL) {}
}
