import Foundation

public struct ObsidianVault: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let path: URL

    public init(path: URL) {
        self.path = path
        self.id = path.path
        self.name = path.lastPathComponent
    }

    public static let transcriptsSubfolder = "Transcripts"

    public var transcriptsFolder: URL {
        path.appendingPathComponent(Self.transcriptsSubfolder, isDirectory: true)
    }
}
