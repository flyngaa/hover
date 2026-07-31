import Foundation

/// The transcript list plus the group (folder) names, as loaded from disk.
struct TranscriptLibrary {
    let transcripts: [SavedTranscript]
    let groups: [String]
}

/// Owns everything to do with transcript files on disk: listing, searching,
/// reading, renaming, moving, deleting, and the markdown format they're saved in.
///
/// The seam that keeps file I/O out of the views and the engine. Production uses
/// ``FileTranscriptStore``; a test can supply an in-memory fake. Callers pass the
/// current output directory in, so the store stays stateless (the *setting* of
/// which directory to use lives with the engine).
protocol TranscriptStore: Sendable {
    /// List all transcripts (and group folders) under `directory`.
    func load(in directory: URL) -> TranscriptLibrary

    /// Rename a transcript in place. Returns its new path, or nil if the rename
    /// didn't happen (empty/unchanged name, collision, or I/O failure).
    func rename(_ transcript: SavedTranscript, to newName: String) -> URL?

    /// Move a transcript into `group` (a subfolder of `directory`), or to the
    /// root when `group` is nil. Returns its new path, or nil if nothing moved.
    func move(_ transcript: SavedTranscript, toGroup group: String?, in directory: URL) -> URL?

    /// Move transcripts out of their current folder and into `directory`, keeping
    /// each one's group subfolder. Used when the output folder changes and the
    /// user wants their existing transcripts to follow.
    /// - Returns: how many files actually moved.
    func relocate(_ transcripts: [SavedTranscript], to directory: URL) -> Int

    /// Delete a transcript's file.
    func delete(_ transcript: SavedTranscript)

    /// Whether a transcript matches a search query (by name or file contents).
    func matches(_ transcript: SavedTranscript, query: String) -> Bool

    /// The display text of a transcript (heading stripped), or a fallback string.
    func content(of transcript: SavedTranscript) -> String

    /// Write a transcript's markdown to `url`.
    func write(title: String, body: String, to url: URL)
}

/// ``TranscriptStore`` backed by the local filesystem.
struct FileTranscriptStore: TranscriptStore {

    // MARK: - File-type knowledge

    static let outputFileExtension = "md"
    static let supportedFileExtensions = ["md", "txt"]

    static func isTranscriptFile(_ url: URL) -> Bool {
        supportedFileExtensions.contains(url.pathExtension.lowercased())
    }

    static func isReservedDirectory(_ name: String) -> Bool {
        name == "models"
    }

    // MARK: - Formatting

    static func markdownContent(title: String, body: String) -> String {
        let heading = recordingName(from: title)
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "# \(heading)\n" }
        return "# \(heading)\n\n\(trimmed)\n"
    }

    /// Plain text for display and copy — strips the markdown heading from saved files.
    static func displayText(fromFile content: String) -> String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.hasPrefix("# ") == true else { return content }

        var bodyLines = Array(lines.dropFirst())
        while bodyLines.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            bodyLines.removeFirst()
        }
        return bodyLines.joined(separator: "\n")
    }

    // MARK: - Recording names

    /// A recording is named after the moment it started, and the sidebar reads
    /// its date back out of that name — so the format is defined once here and
    /// both directions go through ``title(for:)`` and ``date(fromRecordingName:)``.
    private static let titleDateFormat = "yyyy-MM-dd_HH-mm"

    private static var titleFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = titleDateFormat
        return formatter
    }

    /// The name a recording started at `date` is saved under (no extension).
    static func title(for date: Date) -> String {
        titleFormatter.string(from: date)
    }

    /// The moment a recording started, recovered from its name, or nil if the
    /// name wasn't written by us.
    static func date(fromRecordingName name: String) -> Date? {
        titleFormatter.date(from: String(name.prefix(titleDateFormat.count)))
    }

    /// Strips the legacy `transcript_` prefix from older filenames.
    static func recordingName(from filename: String) -> String {
        let prefix = "transcript_"
        if filename.hasPrefix(prefix) {
            return String(filename.dropFirst(prefix.count))
        }
        return filename
    }

    // MARK: - Listing

    func load(in directory: URL) -> TranscriptLibrary {
        let fm = FileManager.default

        var result: [SavedTranscript] = []
        var groupNames: [String] = []

        func makeTranscript(_ file: URL, group: String?) -> SavedTranscript {
            let name = Self.recordingName(from: file.deletingPathExtension().lastPathComponent)
            let date = Self.date(fromRecordingName: name)
                ?? (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate)
                ?? .distantPast
            let id = group.map { "\($0)/\(file.lastPathComponent)" } ?? file.lastPathComponent
            return SavedTranscript(id: id, name: name, date: date, path: file, group: group)
        }

        if let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey], options: .skipsHiddenFiles) {
            for entry in entries {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    guard !Self.isReservedDirectory(entry.lastPathComponent) else { continue }
                    groupNames.append(entry.lastPathComponent)
                    if let files = try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles) {
                        result += files.filter { Self.isTranscriptFile($0) }
                            .map { makeTranscript($0, group: entry.lastPathComponent) }
                    }
                } else if Self.isTranscriptFile(entry) {
                    result.append(makeTranscript(entry, group: nil))
                }
            }
        }

        return TranscriptLibrary(
            transcripts: result.sorted { $0.date > $1.date },
            groups: groupNames.sorted()
        )
    }

    // MARK: - Mutations

    func rename(_ transcript: SavedTranscript, to newName: String) -> URL? {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty, clean != transcript.name else { return nil }

        let dest = transcript.path.deletingLastPathComponent()
            .appendingPathComponent(clean + ".\(Self.outputFileExtension)")
        guard !FileManager.default.fileExists(atPath: dest.path) else { return nil }
        do {
            if transcript.path.pathExtension.lowercased() == Self.outputFileExtension {
                try FileManager.default.moveItem(at: transcript.path, to: dest)
            } else {
                let raw = (try? String(contentsOf: transcript.path, encoding: .utf8)) ?? ""
                let markdown = Self.markdownContent(title: clean, body: Self.displayText(fromFile: raw))
                try markdown.write(to: dest, atomically: true, encoding: .utf8)
                try FileManager.default.removeItem(at: transcript.path)
            }
        } catch {
            return nil
        }
        return dest
    }

    func move(_ transcript: SavedTranscript, toGroup group: String?, in directory: URL) -> URL? {
        let fm = FileManager.default
        var destDir = directory
        if let group {
            let clean = group.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "/", with: "-")
            guard !clean.isEmpty else { return nil }
            destDir = destDir.appendingPathComponent(clean)
            try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        }
        let dest = destDir.appendingPathComponent(transcript.path.lastPathComponent)
        guard dest != transcript.path, !fm.fileExists(atPath: dest.path) else { return nil }
        do {
            try fm.moveItem(at: transcript.path, to: dest)
        } catch {
            return nil
        }
        return dest
    }

    func relocate(_ transcripts: [SavedTranscript], to directory: URL) -> Int {
        let fm = FileManager.default
        var moved = 0

        for transcript in transcripts {
            var destDir = directory
            if let group = transcript.group {
                destDir = destDir.appendingPathComponent(group)
            }
            guard destDir.path != transcript.path.deletingLastPathComponent().path else { continue }
            guard (try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)) != nil
            else { continue }

            // A same-named file in the destination is someone else's — never
            // overwrite it, and never drop ours on the floor either.
            let dest = Self.availableName(for: transcript.path.lastPathComponent, in: destDir)
            guard let dest else { continue }
            if (try? fm.moveItem(at: transcript.path, to: dest)) != nil { moved += 1 }
        }
        return moved
    }

    /// A free filename in `directory`, suffixing " 2", " 3", … past collisions.
    /// Nil if there's no free name within a sane number of tries.
    private static func availableName(for filename: String, in directory: URL, limit: Int = 50) -> URL? {
        let candidate = directory.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }

        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        for suffix in 2...limit {
            let next = directory
                .appendingPathComponent("\(base) \(suffix)")
                .appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: next.path) { return next }
        }
        return nil
    }

    func delete(_ transcript: SavedTranscript) {
        try? FileManager.default.removeItem(at: transcript.path)
    }

    // MARK: - Reading

    func matches(_ transcript: SavedTranscript, query: String) -> Bool {
        if transcript.name.localizedCaseInsensitiveContains(query) { return true }
        if let content = try? String(contentsOf: transcript.path, encoding: .utf8),
           content.localizedCaseInsensitiveContains(query) { return true }
        return false
    }

    func content(of transcript: SavedTranscript) -> String {
        let raw = (try? String(contentsOf: transcript.path, encoding: .utf8)) ?? "Could not load transcript."
        return Self.displayText(fromFile: raw)
    }

    func write(title: String, body: String, to url: URL) {
        let markdown = Self.markdownContent(title: title, body: body)
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
    }
}
