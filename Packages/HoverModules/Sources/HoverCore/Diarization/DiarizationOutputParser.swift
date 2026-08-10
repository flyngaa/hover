import Foundation

public enum DiarizationOutputParser {
    public static func nativeTurns(_ output: String) -> [SpeakerTurn]? {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            nativeTurnLine(String(line))
        }
    }

    public static func pythonTurns(_ output: String) -> [SpeakerTurn]? {
        guard let data = output.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let segments = object["segments"] as? [[String: Any]]
        else { return nil }
        return segments.compactMap { segment in
            guard let start = (segment["start"] as? NSNumber)?.doubleValue,
                let end = (segment["end"] as? NSNumber)?.doubleValue,
                let speaker = (segment["speaker"] as? NSNumber)?.intValue
            else { return nil }
            return SpeakerTurn(start: start, end: end, speaker: speaker)
        }
    }

    private static func nativeTurnLine(_ line: String) -> SpeakerTurn? {
        let pattern = #"^\s*([0-9]+(?:\.[0-9]+)?)\s+--\s+([0-9]+(?:\.[0-9]+)?)\s+speaker_(\d+)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
            let startRange = Range(match.range(at: 1), in: line),
            let endRange = Range(match.range(at: 2), in: line),
            let speakerRange = Range(match.range(at: 3), in: line),
            let start = Double(line[startRange]),
            let end = Double(line[endRange]),
            let speaker = Int(line[speakerRange])
        else { return nil }
        return SpeakerTurn(start: start, end: end, speaker: speaker)
    }
}
