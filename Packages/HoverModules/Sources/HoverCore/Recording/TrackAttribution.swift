import Foundation

/// Merges timestamped mic/system transcript segments into labeled Markdown.
public enum TrackAttribution {
    /// Chronological `**Mic:**` / `**System:**` paragraphs. Consecutive same-track
    /// segments are joined with spaces into one paragraph; overlapping intervals
    /// stay as separate paragraphs (honest for two independent pipes).
    public static func merge(segments: [TextSegment]) -> String {
        let sorted = segments.sorted { a, b in
            if a.start != b.start { return a.start < b.start }
            if a.end != b.end { return a.end < b.end }
            return a.source.sortOrder < b.source.sortOrder
        }

        var paragraphs: [(source: AudioSource, texts: [String])] = []
        for segment in sorted {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = paragraphs.last, last.source == segment.source {
                paragraphs[paragraphs.count - 1].texts.append(text)
            } else {
                paragraphs.append((segment.source, [text]))
            }
        }

        return paragraphs.map { source, texts in
            "**\(source.label):** \(texts.joined(separator: " "))"
        }.joined(separator: "\n\n")
    }
}
