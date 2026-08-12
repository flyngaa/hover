import Testing

@testable import HoverCore

@Suite struct TrackAttributionTests {

    @Test func emptySegmentsYieldEmptyBody() {
        #expect(TrackAttribution.merge(segments: []) == "")
    }

    @Test func singleTrackKeepsOneParagraph() {
        let body = TrackAttribution.merge(segments: [
            TextSegment(start: 0, end: 1, text: "hello", source: .microphone),
            TextSegment(start: 1, end: 2, text: "world", source: .microphone),
        ])
        #expect(body == "**Mic:** hello world")
    }

    @Test func interleavesByStartTime() {
        let body = TrackAttribution.merge(segments: [
            TextSegment(start: 2, end: 4, text: "from the call", source: .system),
            TextSegment(start: 0, end: 1.5, text: "can you hear me", source: .microphone),
            TextSegment(start: 4.5, end: 6, text: "yes thanks", source: .microphone),
        ])
        #expect(
            body == """
                **Mic:** can you hear me

                **System:** from the call

                **Mic:** yes thanks
                """
        )
    }

    @Test func exactTiesPreferMicBeforeSystem() {
        let body = TrackAttribution.merge(segments: [
            TextSegment(start: 1, end: 2, text: "system side", source: .system),
            TextSegment(start: 1, end: 2, text: "mic side", source: .microphone),
        ])
        #expect(
            body == """
                **Mic:** mic side

                **System:** system side
                """
        )
    }

    @Test func overlappingIntervalsStaySeparateParagraphs() {
        let body = TrackAttribution.merge(segments: [
            TextSegment(start: 0, end: 3, text: "talking over", source: .microphone),
            TextSegment(start: 1, end: 4, text: "the meeting", source: .system),
        ])
        #expect(
            body == """
                **Mic:** talking over

                **System:** the meeting
                """
        )
    }

    @Test func blankSegmentsAreSkipped() {
        let body = TrackAttribution.merge(segments: [
            TextSegment(start: 0, end: 1, text: "  ", source: .microphone),
            TextSegment(start: 1, end: 2, text: "kept", source: .system),
        ])
        #expect(body == "**System:** kept")
    }
}
