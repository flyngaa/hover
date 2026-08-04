import Testing
import Foundation
@testable import TranscriberKit

/// Verifies the settings seam: the UserDefaults-backed store round-trips values,
/// and the engine loads from / writes through whatever store it's given.
@Suite struct SettingsTests {

    // MARK: - UserDefaultsSettings

    /// Uses a throwaway UserDefaults suite so the real preferences are untouched.
    private func makeEphemeralDefaults() -> (UserDefaults, String) {
        let suite = "settings-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func userDefaultsDefaultsWhenUnset() {
        let (defaults, suite) = makeEphemeralDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = UserDefaultsSettings(defaults: defaults)
        #expect(settings.inputSource == .both)
        // Speaker tagging is on by default (only off if explicitly turned off).
        #expect(settings.diarizeSpeakers == true)
        #expect(settings.outputDirectoryPath == nil)
    }

    @Test func userDefaultsRoundTrip() {
        let (defaults, suite) = makeEphemeralDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = UserDefaultsSettings(defaults: defaults)
        settings.inputSource = .microphone
        settings.diarizeSpeakers = true
        settings.outputDirectoryPath = "/tmp/out"

        // A fresh instance over the same defaults sees the persisted values.
        let reloaded = UserDefaultsSettings(defaults: defaults)
        #expect(reloaded.inputSource == .microphone)
        #expect(reloaded.diarizeSpeakers == true)
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

    // MARK: - Engine wiring

    private func makeEngine(settings: SettingsStore) -> TranscriberEngine {
        TranscriberEngine(
            transcriber: FakeTranscriber(result: ""),
            audioCapture: FakeAudioCapture(),
            transcriptStore: FakeTranscriptStore(),
            vaultFinder: FakeVaultFinder(),
            settings: settings,
            modelSetup: FakeModelSetup(isComplete: true)
        )
    }

    @Test func engineLoadsSettingsOnInit() {
        let settings = InMemorySettings(
            inputSource: .microphone,
            diarizeSpeakers: true
        )
        let engine = makeEngine(settings: settings)
        #expect(engine.inputSource == .microphone)
        #expect(engine.diarizeSpeakers == true)
    }

    @Test func engineWritesChangesBackToStore() {
        let settings = InMemorySettings()
        let engine = makeEngine(settings: settings)

        engine.diarizeSpeakers = true
        engine.inputSource = .system

        #expect(settings.diarizeSpeakers == true)
        #expect(settings.inputSource == .system)
    }
}
