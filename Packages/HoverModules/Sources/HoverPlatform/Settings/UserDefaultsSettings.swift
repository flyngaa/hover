import Foundation
import HoverCore

/// ``SettingsStore`` backed by `UserDefaults`. Keys match the app's historical
/// names so existing users' preferences carry over.
public final class UserDefaultsSettings: SettingsStore {

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var inputSource: InputSource {
        get { InputSource(rawValue: defaults.string(forKey: Keys.inputSource) ?? "") ?? .both }
        set { defaults.set(newValue.rawValue, forKey: Keys.inputSource) }
    }

    public var diarizeSpeakers: Bool {
        // On by default: only off if the user has explicitly turned it off.
        // (`object(forKey:)` is nil until the key has ever been written.)
        get { defaults.object(forKey: Keys.diarizeSpeakers) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.diarizeSpeakers) }
    }

    public var outputDirectoryPath: String? {
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
