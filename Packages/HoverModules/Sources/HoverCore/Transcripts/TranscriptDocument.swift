import Foundation

/// Pure filename and Markdown policy shared by transcript workflows and stores.
public enum TranscriptDocument {
    public static let outputFileExtension = "md"
    public static let supportedFileExtensions = ["md", "txt"]

    public static func isTranscriptFile(_ url: URL) -> Bool {
        supportedFileExtensions.contains(url.pathExtension.lowercased())
    }

    public static func isReservedDirectory(_ name: String) -> Bool {
        name == "models"
    }

    public static func markdownContent(title: String, body: String) -> String {
        let heading = recordingName(from: title)
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "# \(heading)\n" }
        return "# \(heading)\n\n\(trimmed)\n"
    }

    public static func displayText(fromFile content: String) -> String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(
            String.init)
        guard lines.first?.hasPrefix("# ") == true else { return content }

        var bodyLines = Array(lines.dropFirst())
        while bodyLines.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            bodyLines.removeFirst()
        }
        return bodyLines.joined(separator: "\n")
    }

    private static let titleDateFormat = "yyyy-MM-dd_HH-mm"

    private static var titleFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = titleDateFormat
        return formatter
    }

    public static func title(for date: Date) -> String {
        titleFormatter.string(from: date)
    }

    public static func date(fromRecordingName name: String) -> Date? {
        titleFormatter.date(from: String(name.prefix(titleDateFormat.count)))
    }

    public static func recordingName(from filename: String) -> String {
        let prefix = "transcript_"
        return filename.hasPrefix(prefix) ? String(filename.dropFirst(prefix.count)) : filename
    }
}
