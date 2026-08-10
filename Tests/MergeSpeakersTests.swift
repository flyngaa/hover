import Testing
@testable import HoverApp

/// The speaker-merge step is pure: given transcript segments and detected speaker
/// turns, it attributes the text to speakers — splitting a segment that spans more
/// than one turn — and groups consecutive same-speaker text into paragraphs.
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

    /// A ten-second chunk regularly covers both halves of a quick exchange. Giving
    /// the whole chunk one label used to flatten a two-person conversation into a
    /// single "Speaker 1", so the words are split where the floor changes hands.
    @Test func splitsASegmentThatSpansTwoSpeakers() {
        let turns = [
            SpeakerTurn(start: 0, end: 5, speaker: 0),
            SpeakerTurn(start: 5, end: 10, speaker: 1),
        ]
        let segments = [TextSegment(start: 0, end: 10, text: "one two three four")]
        #expect(
            TranscriberEngine.mergeSpeakers(segments: segments, turns: turns)
                == "**Speaker 1:** one two\n\n**Speaker 2:** three four"
        )
    }

    /// The split follows how long each speaker held the floor, not a plain halving.
    @Test func splitFollowsEachSpeakersShareOfTheSegment() {
        let turns = [
            SpeakerTurn(start: 0, end: 8, speaker: 0),
            SpeakerTurn(start: 8, end: 10, speaker: 1),
        ]
        let segments = [TextSegment(start: 0, end: 10, text: "a b c d e f g h i j")]
        #expect(
            TranscriberEngine.mergeSpeakers(segments: segments, turns: turns)
                == "**Speaker 1:** a b c d e f g h\n\n**Speaker 2:** i j"
        )
    }

    /// An interjection too brief to have earned a word doesn't get an empty
    /// paragraph, and the surrounding speech stays in one piece.
    @Test func aVeryBriefTurnDoesNotProduceAnEmptyParagraph() {
        let turns = [
            SpeakerTurn(start: 0, end: 4.9, speaker: 0),
            SpeakerTurn(start: 4.9, end: 5.0, speaker: 1),
            SpeakerTurn(start: 5.0, end: 10, speaker: 0),
        ]
        let segments = [TextSegment(start: 0, end: 10, text: "one two three four")]
        #expect(
            TranscriberEngine.mergeSpeakers(segments: segments, turns: turns)
                == "**Speaker 1:** one two three four"
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
