import Testing
@testable import TranscriberKit

/// The bits of the Whisper transcriber that don't need the actual `whisper-cli`
/// binary: cleaning its noisy output and the silence check.
@Suite struct WhisperTranscriberTests {

    @Test func cleanupStripsAnnotationsAndBlankLines() {
        #expect(
            WhisperCLITranscriber.cleanWhisperOutput("[BLANK_AUDIO]\n Hello world \n") == "Hello world"
        )
    }

    @Test func cleanupRemovesParentheticalAnnotations() {
        // The paren is removed but internal spacing is left as-is.
        #expect(
            WhisperCLITranscriber.cleanWhisperOutput("Hello (laughs) world") == "Hello  world"
        )
    }

    @Test func cleanupOfPureNoiseIsEmpty() {
        #expect(WhisperCLITranscriber.cleanWhisperOutput("[MUSIC]\n[APPLAUSE]") == "")
    }

    @Test func rms() {
        #expect(abs(WhisperCLITranscriber.rms(of: [0.6, -0.8]) - 0.7071) < 0.0001)
        #expect(WhisperCLITranscriber.rms(of: [Float]()) == 0)
    }
}
