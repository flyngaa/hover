import Testing
import Foundation
@testable import TranscriberKit

/// The moth in the menu bar has to follow the engine whatever started the
/// recording — the Record button, or the keyboard shortcut. It used to be driven
/// by a SwiftUI `onChange` living inside the window, which doesn't run unless the
/// window is being re-rendered, so shortcut-started recordings left it white.
@MainActor
@Suite struct MenuBarMothTests {

    private func makeEngine() -> TranscriberEngine {
        TranscriberEngine(
            transcriber: FakeTranscriber(result: ""),
            audioCapture: FakeAudioCapture(),
            transcriptStore: FakeTranscriptStore(),
            vaultFinder: FakeVaultFinder(),
            settings: InMemorySettings()
        )
    }

    /// The moth reacts one main-actor turn after the engine changes, so give it
    /// a moment rather than asserting immediately.
    private func wait(for moth: MenuBarMoth, toShowRecording expected: Bool) async -> Bool {
        for _ in 0..<100 { // ~1s max
            if moth.isRecording == expected { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    @Test func turnsRedWhenRecordingStarts() async {
        let engine = makeEngine()
        let moth = MenuBarMoth()
        moth.follow(engine)
        #expect(!moth.isRecording)

        engine.isRecording = true
        #expect(await wait(for: moth, toShowRecording: true))
    }

    @Test func goesBackToNormalWhenRecordingStops() async {
        let engine = makeEngine()
        let moth = MenuBarMoth()
        moth.follow(engine)

        engine.isRecording = true
        #expect(await wait(for: moth, toShowRecording: true))

        // The second change proves the moth keeps watching, rather than
        // reacting once and going deaf.
        engine.isRecording = false
        #expect(await wait(for: moth, toShowRecording: false))
    }

    @Test func picksUpARecordingThatWasAlreadyRunning() async {
        let engine = makeEngine()
        engine.isRecording = true

        let moth = MenuBarMoth()
        moth.follow(engine)
        #expect(moth.isRecording)
    }
}
