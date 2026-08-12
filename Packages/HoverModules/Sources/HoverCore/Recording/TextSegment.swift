import Foundation

/// A transcribed slice positioned on the shared recording timeline.
public struct TextSegment: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public var source: AudioSource

    public init(start: Double, end: Double, text: String, source: AudioSource) {
        self.start = start
        self.end = end
        self.text = text
        self.source = source
    }
}
