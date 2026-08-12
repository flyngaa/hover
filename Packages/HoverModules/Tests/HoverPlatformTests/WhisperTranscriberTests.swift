import HoverCore
import Testing

@testable import HoverPlatform

/// The bits of the Whisper transcriber that don't need the actual `whisper-cli`
/// binary: cleaning its noisy output.
@Suite struct WhisperTranscriberTests {

    @Test func cleanupStripsAnnotationsAndBlankLines() {
        #expect(
            WhisperCLITranscriber.cleanWhisperOutput("[BLANK_AUDIO]\n Hello world \n")
                == "Hello world"
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
}
