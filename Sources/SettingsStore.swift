import Foundation

/// Where the app's persisted preferences live.
///
/// The seam between the engine and `UserDefaults`. Production uses
/// ``UserDefaultsSettings``; tests use ``InMemorySettings`` (or a throwaway
/// `UserDefaults` suite) so they never read or write the real user defaults.
protocol SettingsStore: AnyObject {
    /// Which audio source to record (system, mic, or both).
    var inputSource: InputSource { get set }
    /// Whether recordings are analyzed for speaker labels after Stop.
    var diarizeSpeakers: Bool { get set }
    /// The one folder transcripts are saved to, or nil to use the default.
    /// May point inside an Obsidian vault; Hover doesn't care which it is.
    var outputDirectoryPath: String? { get set }
}

/// ``SettingsStore`` backed by `UserDefaults`. Keys match the app's historical
/// names so existing users' preferences carry over.
final class UserDefaultsSettings: SettingsStore {

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var inputSource: InputSource {
        get { InputSource(rawValue: defaults.string(forKey: Keys.inputSource) ?? "") ?? .both }
        set { defaults.set(newValue.rawValue, forKey: Keys.inputSource) }
    }

    var diarizeSpeakers: Bool {
        // On by default: only off if the user has explicitly turned it off.
        // (`object(forKey:)` is nil until the key has ever been written.)
        get { defaults.object(forKey: Keys.diarizeSpeakers) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.diarizeSpeakers) }
    }

    var outputDirectoryPath: String? {
        get { defaults.string(forKey: Keys.outputDirectory) }
        set { setOptionalString(newValue, forKey: Keys.outputDirectory) }
    }

    private func setOptionalString(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private enum Keys {
        static let inputSource = "inputSource"
        static let diarizeSpeakers = "diarizeSpeakers"
        static let outputDirectory = "outputDirectory"
    }
}

/// ``SettingsStore`` that keeps values only in memory. Handy for tests and
/// SwiftUI previews where touching real user defaults is undesirable.
final class InMemorySettings: SettingsStore {
    var inputSource: InputSource
    var diarizeSpeakers: Bool
    var outputDirectoryPath: String?

    init(
        inputSource: InputSource = .both,
        diarizeSpeakers: Bool = false,
        outputDirectoryPath: String? = nil
    ) {
        self.inputSource = inputSource
        self.diarizeSpeakers = diarizeSpeakers
        self.outputDirectoryPath = outputDirectoryPath
    }
}
