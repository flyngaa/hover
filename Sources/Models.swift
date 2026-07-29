import Foundation

enum InputSource: String, CaseIterable, Identifiable {
    case both
    case system
    case microphone

    var id: String { rawValue }

    var label: String {
        switch self {
        case .both: return "Both"
        case .system: return "System Audio"
        case .microphone: return "Microphone"
        }
    }
}

struct ObsidianVault: Identifiable, Hashable {
    let id: String      // absolute path, used as a stable identifier
    let name: String    // vault folder name shown to the user
    let path: URL

    init(path: URL) {
        self.path = path
        self.id = path.path
        self.name = path.lastPathComponent
    }

    /// Transcripts are saved into this subfolder rather than the vault root, so
    /// they stay tidy alongside the user's own notes.
    static let transcriptsSubfolder = "Transcripts"

    /// The folder inside the vault that Hover saves transcripts into when this
    /// vault is the chosen output destination.
    var transcriptsFolder: URL {
        path.appendingPathComponent(Self.transcriptsSubfolder, isDirectory: true)
    }
}

struct SavedTranscript: Identifiable, Hashable {
    let id: String
    let name: String
    let date: Date
    let path: URL
    let group: String?

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: SavedTranscript, rhs: SavedTranscript) -> Bool { lhs.id == rhs.id }
}
