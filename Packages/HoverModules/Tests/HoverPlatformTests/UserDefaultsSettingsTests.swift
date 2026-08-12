import Foundation
import HoverCore
import Testing

@testable import HoverPlatform

@Suite struct UserDefaultsSettingsTests {
    private func makeEphemeralDefaults() -> (UserDefaults, String) {
        let suite = "settings-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func defaultsWhenUnset() {
        let (defaults, suite) = makeEphemeralDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = UserDefaultsSettings(defaults: defaults)
        #expect(settings.inputSource == .both)
        #expect(settings.outputDirectoryPath == nil)
    }

    @Test func roundTrip() {
        let (defaults, suite) = makeEphemeralDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = UserDefaultsSettings(defaults: defaults)
        settings.inputSource = .microphone
        settings.outputDirectoryPath = "/tmp/out"

        let reloaded = UserDefaultsSettings(defaults: defaults)
        #expect(reloaded.inputSource == .microphone)
        #expect(reloaded.outputDirectoryPath == "/tmp/out")
    }

    @Test func settingOptionalToNilClearsIt() {
        let (defaults, suite) = makeEphemeralDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = UserDefaultsSettings(defaults: defaults)
        settings.outputDirectoryPath = "/x"
        settings.outputDirectoryPath = nil
        #expect(settings.outputDirectoryPath == nil)
    }
}
