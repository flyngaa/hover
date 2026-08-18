import Testing

@testable import HoverApp

@MainActor
@Suite struct RecordingPresenceTests {
    @Test func recordingWinsOverEverything() {
        #expect(
            RecordingPresence.combine(local: .idle, remotes: [.recording]) == .recording
        )
        #expect(
            RecordingPresence.combine(local: .processing, remotes: [.idle, .recording])
                == .recording
        )
        #expect(
            RecordingPresence.combine(local: .recording, remotes: []) == .recording
        )
    }

    @Test func processingWinsOverIdle() {
        #expect(
            RecordingPresence.combine(local: .idle, remotes: [.processing, .idle]) == .processing
        )
        #expect(
            RecordingPresence.combine(local: .processing, remotes: []) == .processing
        )
    }

    @Test func idleWhenNobodyIsBusy() {
        #expect(RecordingPresence.combine(local: .idle, remotes: []) == .idle)
        #expect(RecordingPresence.combine(local: .idle, remotes: [.idle, .idle]) == .idle)
    }
}
