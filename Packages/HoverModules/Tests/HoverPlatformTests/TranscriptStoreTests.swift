import Foundation
import HoverCore
import Testing

@testable import HoverPlatform

/// Covers both the pure formatting rules and the real filesystem operations of
/// `FileTranscriptStore`, using a throwaway temp directory for the I/O tests.
///
/// A `final class` suite so each test gets a fresh temp directory via `init`,
/// cleaned up in `deinit`.
@Suite final class TranscriptStoreTests {

    private let dir: URL
    private let store = FileTranscriptStore()

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcriber-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    private func transcript(_ url: URL, name: String, group: String? = nil) -> SavedTranscript {
        SavedTranscript(id: url.lastPathComponent, name: name, date: .now, path: url, group: group)
    }

    // MARK: - Formatting (pure)

    @Test func markdownContent() {
        #expect(
            FileTranscriptStore.markdownContent(title: "2026-07-23_10-00", body: "hello world")
                == "# 2026-07-23_10-00\n\nhello world\n"
        )
    }

    @Test func markdownContentEmptyBody() {
        #expect(
            FileTranscriptStore.markdownContent(title: "2026-07-23_10-00", body: "   \n ")
                == "# 2026-07-23_10-00\n"
        )
    }

    @Test func markdownContentStripsLegacyPrefix() {
        #expect(
            FileTranscriptStore.markdownContent(title: "transcript_meeting", body: "hi")
                == "# meeting\n\nhi\n"
        )
    }

    @Test func displayTextStripsHeading() {
        #expect(
            FileTranscriptStore.displayText(fromFile: "# Title\n\nline1\nline2") == "line1\nline2"
        )
    }

    @Test func displayTextWithoutHeadingIsUnchanged() {
        #expect(
            FileTranscriptStore.displayText(fromFile: "no heading\nline2") == "no heading\nline2"
        )
    }

    @Test func recordingName() {
        #expect(FileTranscriptStore.recordingName(from: "transcript_x") == "x")
        #expect(FileTranscriptStore.recordingName(from: "x") == "x")
    }

    @Test func fileTypeKnowledge() {
        #expect(FileTranscriptStore.isTranscriptFile(URL(fileURLWithPath: "a.md")))
        #expect(FileTranscriptStore.isTranscriptFile(URL(fileURLWithPath: "a.txt")))
        #expect(FileTranscriptStore.isTranscriptFile(URL(fileURLWithPath: "a.png")) == false)
        #expect(FileTranscriptStore.isReservedDirectory("models"))
        #expect(FileTranscriptStore.isReservedDirectory("Interviews") == false)
    }

    // MARK: - Filesystem

    @Test func writeAndReadRoundTrip() throws {
        let url = dir.appendingPathComponent("t.md")
        try store.write(title: "t", body: "hello", to: url)

        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(raw == "# t\n\nhello\n")
        // content() strips the heading; the body keeps its trailing newline.
        #expect(try store.content(of: transcript(url, name: "t")) == "hello\n")
    }

    @Test func recordingDestinationDoesNotOverwriteSameMinuteRecording() throws {
        let date = Date(timeIntervalSince1970: 1_785_000_000)
        let first = FileTranscriptStore.availableRecordingDestination(for: date, in: dir)
        try Data().write(to: first.url)

        let second = FileTranscriptStore.availableRecordingDestination(for: date, in: dir)

        #expect(second.title == first.title + " 2")
        #expect(second.url != first.url)
    }

    @Test func loadListsTranscriptsAndGroupsAndSkipsReserved() throws {
        // A transcript at the root.
        try store.write(
            title: "root-note", body: "a", to: dir.appendingPathComponent("root-note.md"))
        // A transcript inside a group folder.
        let group = dir.appendingPathComponent("GroupA")
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        try store.write(
            title: "group-note", body: "b", to: group.appendingPathComponent("group-note.md"))
        // A file inside the reserved "models" folder — must be ignored.
        let models = dir.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try store.write(title: "ignore", body: "c", to: models.appendingPathComponent("ignore.md"))

        let library = try store.load(in: dir)
        #expect(library.transcripts.count == 2)
        #expect(library.groups == ["GroupA"])
        #expect(library.transcripts.contains { $0.group == "GroupA" })
    }

    @Test func matchesByNameAndContent() throws {
        let url = dir.appendingPathComponent("meeting-notes.md")
        try store.write(title: "meeting-notes", body: "the quick brown fox", to: url)
        let t = transcript(url, name: "meeting-notes")

        #expect(store.matches(t, query: "meeting"))  // name
        #expect(store.matches(t, query: "quick"))  // content
        #expect(store.matches(t, query: "zzz") == false)
    }

    @Test func rename() throws {
        let url = dir.appendingPathComponent("old.md")
        try store.write(title: "old", body: "x", to: url)

        let renamed = try store.rename(transcript(url, name: "old"), to: "new")
        #expect(renamed.path.lastPathComponent == "new.md")
        #expect(FileManager.default.fileExists(atPath: renamed.path.path))
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    @Test func moveIntoGroup() throws {
        let url = dir.appendingPathComponent("m.md")
        try store.write(title: "m", body: "x", to: url)

        let moved = try store.move(transcript(url, name: "m"), toGroup: "G", in: dir)
        #expect(moved.path == dir.appendingPathComponent("G/m.md"))
        #expect(FileManager.default.fileExists(atPath: moved.path.path))
    }

    @Test func delete() throws {
        let url = dir.appendingPathComponent("d.md")
        try store.write(title: "d", body: "x", to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))

        try store.delete(transcript(url, name: "d"))
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    // MARK: - Relocating to a new output folder

    /// Transcripts move out of the old folder entirely — no copy is left behind —
    /// and group subfolders are recreated in the destination.
    @Test func relocateMovesFilesAndKeepsGroups() throws {
        let destination = dir.appendingPathComponent("destination")
        let rootURL = dir.appendingPathComponent("root.md")
        let groupDir = dir.appendingPathComponent("GroupA")
        try FileManager.default.createDirectory(at: groupDir, withIntermediateDirectories: true)
        let groupURL = groupDir.appendingPathComponent("grouped.md")
        try store.write(title: "root", body: "a", to: rootURL)
        try store.write(title: "grouped", body: "b", to: groupURL)

        let report = store.relocate(
            [
                transcript(rootURL, name: "root"),
                transcript(groupURL, name: "grouped", group: "GroupA"),
            ],
            to: destination
        )

        #expect(report.moved.count == 2)
        #expect(report.failures.isEmpty)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: destination.appendingPathComponent("root.md").path))
        #expect(fm.fileExists(atPath: destination.appendingPathComponent("GroupA/grouped.md").path))
        #expect(fm.fileExists(atPath: rootURL.path) == false)
        #expect(fm.fileExists(atPath: groupURL.path) == false)
    }

    /// An unrelated file with the same name in the destination must survive, and
    /// the incoming transcript must not be dropped either.
    @Test func relocateDoesNotOverwriteExistingFile() throws {
        let destination = dir.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try store.write(
            title: "clash", body: "theirs", to: destination.appendingPathComponent("clash.md"))

        let source = dir.appendingPathComponent("clash.md")
        try store.write(title: "clash", body: "ours", to: source)

        #expect(
            store.relocate([transcript(source, name: "clash")], to: destination).moved.count == 1)

        let kept = try String(
            contentsOf: destination.appendingPathComponent("clash.md"), encoding: .utf8)
        let moved = try String(
            contentsOf: destination.appendingPathComponent("clash 2.md"), encoding: .utf8)
        #expect(kept.contains("theirs"))
        #expect(moved.contains("ours"))
        #expect(FileManager.default.fileExists(atPath: source.path) == false)
    }

    /// Relocating to the folder a transcript already sits in is a no-op, not a
    /// self-move that would lose the file.
    @Test func relocateToSameFolderDoesNothing() throws {
        let url = dir.appendingPathComponent("stay.md")
        try store.write(title: "stay", body: "x", to: url)

        let report = store.relocate([transcript(url, name: "stay")], to: dir)
        #expect(report.moved.isEmpty)
        #expect(report.unchanged.count == 1)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func missingDirectoryIsNotReportedAsAnEmptyLibrary() {
        let missing = dir.appendingPathComponent("missing")
        #expect(throws: TranscriptStoreError.self) {
            try store.load(in: missing)
        }
    }

    @Test func writeFailureIsExplicit() {
        #expect(throws: TranscriptStoreError.self) {
            try store.write(title: "blocked", body: "body", to: dir)
        }
    }

    @Test func renameCollisionIsDistinctFromSuccess() throws {
        let first = dir.appendingPathComponent("first.md")
        let second = dir.appendingPathComponent("second.md")
        try store.write(title: "first", body: "a", to: first)
        try store.write(title: "second", body: "b", to: second)

        #expect(throws: TranscriptStoreError.destinationExists) {
            try store.rename(self.transcript(first, name: "first"), to: "second")
        }
        #expect(FileManager.default.fileExists(atPath: first.path))
    }

    @Test func failedDeleteDoesNotPretendToSucceed() {
        let missing = dir.appendingPathComponent("missing.md")
        #expect(throws: TranscriptStoreError.self) {
            try store.delete(self.transcript(missing, name: "missing"))
        }
    }

    @Test func partialRelocationReportsExactFailure() throws {
        let existing = dir.appendingPathComponent("existing.md")
        let missing = dir.appendingPathComponent("missing.md")
        let destination = dir.appendingPathComponent("destination")
        try store.write(title: "existing", body: "body", to: existing)

        let report = store.relocate(
            [transcript(existing, name: "existing"), transcript(missing, name: "missing")],
            to: destination
        )

        #expect(report.moved.count == 1)
        #expect(report.failures.map(\.transcript.name) == ["missing"])
    }
}
