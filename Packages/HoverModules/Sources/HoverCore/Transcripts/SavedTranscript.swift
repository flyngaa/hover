import Foundation

public struct SavedTranscript: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let date: Date
    public let path: URL
    public let group: String?

    public init(id: String, name: String, date: Date, path: URL, group: String?) {
        self.id = id
        self.name = name
        self.date = date
        self.path = path
        self.group = group
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public static func == (lhs: SavedTranscript, rhs: SavedTranscript) -> Bool {
        lhs.id == rhs.id
    }
}
