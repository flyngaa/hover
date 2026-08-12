import Foundation

public enum InputSource: String, CaseIterable, Identifiable, Sendable {
    case both
    case system
    case microphone

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .both: return "Both"
        case .system: return "System Audio"
        case .microphone: return "Microphone"
        }
    }
}
