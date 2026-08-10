import Foundation

public enum SpeakerAttribution {
    public static func merge(segments: [TextSegment], turns: [SpeakerTurn]) -> String {
        let ordered = turns.sorted { $0.start < $1.start }
        var paragraphs: [String] = []
        var currentSpeaker = Int.min
        var currentText = ""
        var displayNumber: [Int: Int] = [:]

        func label(for raw: Int) -> String {
            guard raw >= 0 else { return "Unknown speaker" }
            if let number = displayNumber[raw] { return "Speaker \(number)" }
            let number = displayNumber.count + 1
            displayNumber[raw] = number
            return "Speaker \(number)"
        }
        func flush() {
            guard !currentText.isEmpty else { return }
            paragraphs.append("**\(label(for: currentSpeaker)):** \(currentText)")
        }

        for segment in segments {
            for piece in attribute(segment, to: ordered) {
                if piece.speaker == currentSpeaker {
                    currentText += " " + piece.text
                } else {
                    flush()
                    currentSpeaker = piece.speaker
                    currentText = piece.text
                }
            }
        }
        flush()
        return paragraphs.joined(separator: "\n\n")
    }

    private static func attribute(
        _ segment: TextSegment,
        to turns: [SpeakerTurn]
    ) -> [(speaker: Int, text: String)] {
        let text = segment.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return [] }
        var shares: [(speaker: Int, seconds: Double)] = []
        for turn in turns {
            let overlap = min(segment.end, turn.end) - max(segment.start, turn.start)
            guard overlap > 0 else { continue }
            if shares.last?.speaker == turn.speaker {
                shares[shares.count - 1].seconds += overlap
            } else {
                shares.append((turn.speaker, overlap))
            }
        }
        guard shares.count > 1 else { return [(shares.first?.speaker ?? -1, text)] }

        let words = text.split(separator: " ").map(String.init)
        let total = shares.reduce(0) { $0 + $1.seconds }
        var pieces: [(speaker: Int, text: String)] = []
        var wordIndex = 0
        var elapsed = 0.0
        for (index, share) in shares.enumerated() {
            elapsed += share.seconds
            let end =
                index == shares.count - 1
                ? words.count
                : min(
                    max(Int((elapsed / total * Double(words.count)).rounded()), wordIndex),
                    words.count
                )
            guard end > wordIndex else { continue }
            pieces.append((share.speaker, words[wordIndex..<end].joined(separator: " ")))
            wordIndex = end
        }
        return pieces
    }
}
