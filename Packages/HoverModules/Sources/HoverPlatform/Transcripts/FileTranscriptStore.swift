import Foundation
import HoverCore

/// ``TranscriptStore`` backed by the local filesystem.
public struct FileTranscriptStore: TranscriptStore {

    public init() {}

    // MARK: - File-type knowledge

    public static let outputFileExtension = TranscriptDocument.outputFileExtension
    public static let supportedFileExtensions = TranscriptDocument.supportedFileExtensions

    public static func isTranscriptFile(_ url: URL) -> Bool {
        TranscriptDocument.isTranscriptFile(url)
    }

    public static func isReservedDirectory(_ name: String) -> Bool {
        TranscriptDocument.isReservedDirectory(name)
    }

    // MARK: - Formatting

    public static func markdownContent(title: String, body: String) -> String {
        TranscriptDocument.markdownContent(title: title, body: body)
    }

    /// Plain text for display and copy — strips the markdown heading from saved files.
    public static func displayText(fromFile content: String) -> String {
        TranscriptDocument.displayText(fromFile: content)
    }

    // MARK: - Recording names

    /// A recording is named after the moment it started, and the sidebar reads
    /// its date back out of that name — so the format is defined once here and
    /// both directions go through ``title(for:)`` and ``date(fromRecordingName:)``.
    /// The name a recording started at `date` is saved under (no extension).
    public static func title(for date: Date) -> String {
        TranscriptDocument.title(for: date)
    }

    /// Returns a recording identity that cannot overwrite another recording
    /// started in the same minute. The title and filename always stay aligned.
    public static func availableRecordingDestination(
        for date: Date,
        in directory: URL,
        fileManager: FileManager = .default
    ) -> (title: String, url: URL) {
        let base = title(for: date)
        for suffix in 1...999 {
            let title = suffix == 1 ? base : "\(base) \(suffix)"
            let url =
                directory
                .appendingPathComponent(title)
                .appendingPathExtension(outputFileExtension)
            if !fileManager.fileExists(atPath: url.path) { return (title, url) }
        }

        let title = "\(base) \(UUID().uuidString)"
        return (
            title,
            directory.appendingPathComponent(title).appendingPathExtension(outputFileExtension)
        )
    }

    /// The moment a recording started, recovered from its name, or nil if the
    /// name wasn't written by us.
    public static func date(fromRecordingName name: String) -> Date? {
        TranscriptDocument.date(fromRecordingName: name)
    }

    /// Strips the legacy `transcript_` prefix from older filenames.
    public static func recordingName(from filename: String) -> String {
        TranscriptDocument.recordingName(from: filename)
    }

    // MARK: - Listing

    public func availableRecordingDestination(
        for date: Date,
        in directory: URL
    ) -> (title: String, url: URL) {
        Self.availableRecordingDestination(for: date, in: directory)
    }

    public func load(in directory: URL) throws -> TranscriptLibrary {
        let fm = FileManager.default

        var result: [SavedTranscript] = []
        var groupNames: [String] = []

        func makeTranscript(_ file: URL, group: String?) -> SavedTranscript {
            let name = Self.recordingName(from: file.deletingPathExtension().lastPathComponent)
            let date =
                Self.date(fromRecordingName: name)
                ?? (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate)
                ?? .distantPast
            let id = group.map { "\($0)/\(file.lastPathComponent)" } ?? file.lastPathComponent
            return SavedTranscript(id: id, name: name, date: date, path: file, group: group)
        }

        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
                options: .skipsHiddenFiles
            )
        } catch {
            throw TranscriptStoreError.unreadableDirectory(diagnostic: error.localizedDescription)
        }
        for entry in entries {
            let isDir: Bool
            do {
                isDir = try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            } catch {
                throw TranscriptStoreError.unreadableDirectory(
                    diagnostic: error.localizedDescription)
            }
            if isDir {
                guard !Self.isReservedDirectory(entry.lastPathComponent) else { continue }
                groupNames.append(entry.lastPathComponent)
                do {
                    let files = try fm.contentsOfDirectory(
                        at: entry,
                        includingPropertiesForKeys: [.creationDateKey],
                        options: .skipsHiddenFiles
                    )
                    result += files.filter { Self.isTranscriptFile($0) }
                        .map { makeTranscript($0, group: entry.lastPathComponent) }
                } catch {
                    throw TranscriptStoreError.unreadableDirectory(
                        diagnostic: error.localizedDescription)
                }
            } else if Self.isTranscriptFile(entry) {
                result.append(makeTranscript(entry, group: nil))
            }
        }

        return TranscriptLibrary(
            transcripts: result.sorted { $0.date > $1.date },
            groups: groupNames.sorted()
        )
    }

    // MARK: - Mutations

    public func rename(_ transcript: SavedTranscript, to newName: String) throws -> SavedTranscript
    {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty else { throw TranscriptStoreError.invalidName }
        guard clean != transcript.name else { return transcript }

        let dest = transcript.path.deletingLastPathComponent()
            .appendingPathComponent(clean + ".\(Self.outputFileExtension)")
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            throw TranscriptStoreError.destinationExists
        }
        do {
            if transcript.path.pathExtension.lowercased() == Self.outputFileExtension {
                try FileManager.default.moveItem(at: transcript.path, to: dest)
            } else {
                let raw = try String(contentsOf: transcript.path, encoding: .utf8)
                let markdown = Self.markdownContent(
                    title: clean, body: Self.displayText(fromFile: raw))
                try markdown.write(to: dest, atomically: true, encoding: .utf8)
                try FileManager.default.removeItem(at: transcript.path)
            }
        } catch {
            throw TranscriptStoreError.renameFailed(diagnostic: error.localizedDescription)
        }
        let id =
            transcript.group.map { "\($0)/\(dest.lastPathComponent)" } ?? dest.lastPathComponent
        return SavedTranscript(
            id: id,
            name: clean,
            date: transcript.date,
            path: dest,
            group: transcript.group
        )
    }

    public func move(_ transcript: SavedTranscript, toGroup group: String?, in directory: URL)
        throws -> SavedTranscript
    {
        let fm = FileManager.default
        var destDir = directory
        var destinationGroup: String?
        if let group {
            let clean = group.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "/", with: "-")
            guard !clean.isEmpty else { throw TranscriptStoreError.invalidName }
            destinationGroup = clean
            destDir = destDir.appendingPathComponent(clean)
            do {
                try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            } catch {
                throw TranscriptStoreError.createDirectoryFailed(
                    diagnostic: error.localizedDescription)
            }
        }
        let dest = destDir.appendingPathComponent(transcript.path.lastPathComponent)
        guard dest != transcript.path else { return transcript }
        guard !fm.fileExists(atPath: dest.path) else {
            throw TranscriptStoreError.destinationExists
        }
        do {
            try fm.moveItem(at: transcript.path, to: dest)
        } catch {
            throw TranscriptStoreError.moveFailed(diagnostic: error.localizedDescription)
        }
        let id =
            destinationGroup.map { "\($0)/\(dest.lastPathComponent)" } ?? dest.lastPathComponent
        return SavedTranscript(
            id: id,
            name: transcript.name,
            date: transcript.date,
            path: dest,
            group: destinationGroup
        )
    }

    public func relocate(
        _ transcripts: [SavedTranscript],
        to directory: URL
    ) -> TranscriptRelocationReport {
        let fm = FileManager.default
        var moved: [SavedTranscript] = []
        var unchanged: [SavedTranscript] = []
        var failures: [TranscriptRelocationFailure] = []

        for transcript in transcripts {
            var destDir = directory
            if let group = transcript.group {
                destDir = destDir.appendingPathComponent(group)
            }
            guard destDir.path != transcript.path.deletingLastPathComponent().path else {
                unchanged.append(transcript)
                continue
            }
            do {
                try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            } catch {
                failures.append(
                    .init(
                        transcript: transcript,
                        error: .createDirectoryFailed(diagnostic: error.localizedDescription)
                    ))
                continue
            }

            // A same-named file in the destination is someone else's — never
            // overwrite it, and never drop ours on the floor either.
            let dest = Self.availableName(for: transcript.path.lastPathComponent, in: destDir)
            guard let dest else {
                failures.append(.init(transcript: transcript, error: .noAvailableDestination))
                continue
            }
            do {
                try fm.moveItem(at: transcript.path, to: dest)
                let id =
                    transcript.group.map { "\($0)/\(dest.lastPathComponent)" }
                    ?? dest.lastPathComponent
                moved.append(
                    SavedTranscript(
                        id: id,
                        name: dest.deletingPathExtension().lastPathComponent,
                        date: transcript.date,
                        path: dest,
                        group: transcript.group
                    ))
            } catch {
                failures.append(
                    .init(
                        transcript: transcript,
                        error: .moveFailed(diagnostic: error.localizedDescription)
                    ))
            }
        }
        return TranscriptRelocationReport(
            moved: moved,
            unchanged: unchanged,
            failures: failures
        )
    }

    /// A free filename in `directory`, suffixing " 2", " 3", … past collisions.
    /// Nil if there's no free name within a sane number of tries.
    private static func availableName(for filename: String, in directory: URL, limit: Int = 50)
        -> URL?
    {
        let candidate = directory.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }

        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        for suffix in 2...limit {
            let next =
                directory
                .appendingPathComponent("\(base) \(suffix)")
                .appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: next.path) { return next }
        }
        return nil
    }

    public func delete(_ transcript: SavedTranscript) throws {
        do {
            try FileManager.default.removeItem(at: transcript.path)
        } catch {
            throw TranscriptStoreError.deleteFailed(diagnostic: error.localizedDescription)
        }
    }

    // MARK: - Reading

    public func matches(_ transcript: SavedTranscript, query: String) -> Bool {
        if transcript.name.localizedCaseInsensitiveContains(query) { return true }
        if let content = try? String(contentsOf: transcript.path, encoding: .utf8),
            content.localizedCaseInsensitiveContains(query)
        {
            return true
        }
        return false
    }

    public func content(of transcript: SavedTranscript) throws -> String {
        do {
            return Self.displayText(
                fromFile: try String(contentsOf: transcript.path, encoding: .utf8)
            )
        } catch {
            throw TranscriptStoreError.readFailed(diagnostic: error.localizedDescription)
        }
    }

    public func write(title: String, body: String, to url: URL) throws {
        let markdown = Self.markdownContent(title: title, body: body)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw TranscriptStoreError.writeFailed(diagnostic: error.localizedDescription)
        }
    }

    public func discardDraft(at url: URL) {
        // Cancellation cleanup is deliberately best effort: the user-facing
        // operation is already ending and there is no safe recovery action.
        try? FileManager.default.removeItem(at: url)
    }
}
