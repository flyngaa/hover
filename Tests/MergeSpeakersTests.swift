import Testing
@testable import TranscriberKit

/// The speaker-merge step is pure: given transcript segments and detected speaker
/// turns, it assigns each segment to the best-overlapping speaker and groups
/// consecutive same-speaker text into paragraphs.
@Suite struct MergeSpeakersTests {

    @Test func assignsSegmentsToOverlappingSpeaker() {
        let turns = [
            SpeakerTurn(start: 0, end: 5, speaker: 0),
            SpeakerTurn(start: 5, end: 10, speaker: 1),
        ]
        let segments = [
            TextSegment(start: 0, end: 4, text: "hello"),
            TextSegment(start: 6, end: 9, text: "world"),
        ]
        #expect(
            TranscriberEngine.mergeSpeakers(segments: segments, turns: turns)
                == "**Speaker 1:** hello\n\n**Speaker 2:** world"
        )
    }

    @Test func mergesConsecutiveSameSpeaker() {
        let turns = [SpeakerTurn(start: 0, end: 5, speaker: 0)]
        let segments = [
            TextSegment(start: 0, end: 2, text: "a"),
            TextSegment(start: 2, end: 4, text: "b"),
        ]
        #expect(
            TranscriberEngine.mergeSpeakers(segments: segments, turns: turns) == "**Speaker 1:** a b"
        )
    }

    @Test func unknownSpeakerWhenNoOverlap() {
        let turns = [SpeakerTurn(start: 0, end: 5, speaker: 0)]
        let segments = [TextSegment(start: 100, end: 101, text: "x")]
        #expect(
            TranscriberEngine.mergeSpeakers(segments: segments, turns: turns) == "**Unknown speaker:** x"
        )
    }

    @Test func labelsAreSequentialByFirstAppearance() {
        // Raw cluster ids (5, 2) should surface as Speaker 1, Speaker 2 in order.
        let turns = [
            SpeakerTurn(start: 0, end: 5, speaker: 5),
            SpeakerTurn(start: 5, end: 10, speaker: 2),
        ]
        let segments = [
            TextSegment(start: 1, end: 2, text: "a"),
            TextSegment(start: 6, end: 7, text: "b"),
        ]
        #expect(
            TranscriberEngine.mergeSpeakers(segments: segments, turns: turns)
                == "**Speaker 1:** a\n\n**Speaker 2:** b"
        )
    }
}
