import Foundation

/// Which capture pipe produced a slice of audio or transcript text.
public enum AudioSource: String, Sendable, Equatable, CaseIterable {
    case microphone
    case system

    /// Short Markdown label used in saved transcripts (`**Mic:**` / `**System:**`).
    public var label: String {
        switch self {
        case .microphone: return "Mic"
        case .system: return "System"
        }
    }

    /// Stable tie-break when two segments share the same start/end (Mic first).
    var sortOrder: Int {
        switch self {
        case .microphone: return 0
        case .system: return 1
        }
    }
}
