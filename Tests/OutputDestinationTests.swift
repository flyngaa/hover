import Testing
import Foundation
@testable import TranscriberKit

/// Transcripts live in exactly one folder. These tests pin down how that folder
/// is chosen — including that switching folders never silently abandons files.
///
/// A `final class` suite so each test gets fresh temp directories via `init`,
/// cleaned up in `deinit`. Real directories are needed because the engine falls
/// back to the default folder when a saved path no longer exists.
@Suite final class OutputDestinationTests {

    private let current: URL
    private let elsewhere: URL

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hover-output-tests-\(UUID().uuidString)")
        current = root.appendingPathComponent("Current")
        elsewhere = root.appendingPathComponent("Elsewhere")
        for dir in [current, elsewhere] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: current.deletingLastPathComponent())
    }

    // MARK: - Helpers

    /// Records what it was asked to relocate, and reports a fixed transcript list
    /// so the engine believes the current folder has files in it.
    private final class SpyTranscriptStore: TranscriptStore, @unchecked Sendable {
        var library: TranscriptLibrary
        var relocations: [(transcripts: [SavedTranscript], destination: URL)] = []

        init(transcripts: [SavedTranscript] = []) {
            self.library = TranscriptLibrary(transcripts: transcripts, groups: [])
        }

        func load(in directory: URL) -> TranscriptLibrary { library }
        func rename(_ transcript: SavedTranscript, to newName: String) -> URL? { nil }
        func move(_ transcript: SavedTranscript, toGroup group: String?, in directory: URL) -> URL? { nil }
        func relocate(_ transcripts: [SavedTranscript], to directory: URL) -> Int {
            relocations.append((transcripts, directory))
            return transcripts.count
        }
        func delete(_ transcript: SavedTranscript) {}
        func matches(_ transcript: SavedTranscript, query: String) -> Bool { false }
        func content(of transcript: SavedTranscript) -> String { "" }
        func write(title: String, body: String, to url: URL) {}
    }

    private func makeTranscript(_ name: String) -> SavedTranscript {
        SavedTranscript(
            id: name, name: name, date: .now,
            path: current.appendingPathComponent("\(name).md"), group: nil
        )
    }

    private func makeEngine(
        store: SpyTranscriptStore = SpyTranscriptStore(),
        vaultPaths: [String] = [],
        outputDirectoryPath: String? = nil
    ) -> TranscriberEngine {
        TranscriberEngine(
            transcriber: FakeTranscriber(result: ""),
            audioCapture: FakeAudioCapture(),
            transcriptStore: store,
            vaultFinder: FakeVaultFinder(paths: vaultPaths),
            settings: InMemorySettings(outputDirectoryPath: outputDirectoryPath)
        )
    }

    private func destination(_ url: URL) -> OutputDestination {
        OutputDestination(kind: .custom, name: url.lastPathComponent, directory: url)
    }

    // MARK: - What's on offer

    @Test func standardFolderIsTheDefaultChoice() {
        let engine = makeEngine()
        #expect(engine.currentOutputDestination.kind == .standard)
        #expect(engine.outputDirectory == TranscriberEngine.defaultOutputDirectory)
    }

    /// A vault is offered as a destination pointing at its Transcripts subfolder,
    /// not the vault root.
    @Test func vaultsAreOfferedAsDestinations() throws {
        let engine = makeEngine(vaultPaths: ["/Vaults/Notes"])
        let vault = try #require(engine.outputDestinations.first { $0.kind == .vault })
        #expect(vault.name == "Notes")
        #expect(vault.directory.path == "/Vaults/Notes/Transcripts")
    }

    /// A folder that is neither the standard one nor a vault still shows up, so
    /// the user can see what's currently ticked.
    @Test func chosenFolderIsListedAsItsOwnDestination() {
        let engine = makeEngine(outputDirectoryPath: current.path)
        #expect(engine.currentOutputDestination.kind == .custom)
        #expect(engine.currentOutputDestination.directory.path == current.path)
        #expect(engine.outputDestinations.contains { $0.directory.path == current.path })
    }

    // MARK: - Switching with nothing to lose

    @Test func switchingWithNoTranscriptsAppliesStraightAway() {
        let engine = makeEngine(outputDirectoryPath: current.path)
        engine.requestOutputChange(to: destination(elsewhere))

        #expect(engine.pendingOutputChange == nil)
        #expect(engine.outputDirectory.path == elsewhere.path)
    }

    @Test func switchingToTheSameFolderDoesNothing() {
        let store = SpyTranscriptStore(transcripts: [makeTranscript("a")])
        let engine = makeEngine(store: store, outputDirectoryPath: current.path)

        engine.requestOutputChange(to: destination(current))
        #expect(engine.pendingOutputChange == nil)
    }

    @Test func switchingIsBlockedWhileRecording() {
        let engine = makeEngine(outputDirectoryPath: current.path)
        engine.isRecording = true

        engine.requestOutputChange(to: destination(elsewhere))
        #expect(engine.pendingOutputChange == nil)
        #expect(engine.outputDirectory.path == current.path)
    }

    // MARK: - Switching when transcripts would be left behind

    @Test func switchingWithTranscriptsAsksBeforeApplying() throws {
        let store = SpyTranscriptStore(transcripts: [makeTranscript("a"), makeTranscript("b")])
        let engine = makeEngine(store: store, outputDirectoryPath: current.path)

        engine.requestOutputChange(to: destination(elsewhere))

        let pending = try #require(engine.pendingOutputChange)
        #expect(pending.transcriptCount == 2)
        #expect(pending.origin.path == current.path)
        // Nothing has moved and nothing has been repointed yet.
        #expect(engine.outputDirectory.path == current.path)
        #expect(store.relocations.isEmpty)
    }

    @Test func movingBringsTranscriptsAlong() throws {
        let store = SpyTranscriptStore(transcripts: [makeTranscript("a")])
        let engine = makeEngine(store: store, outputDirectoryPath: current.path)

        engine.requestOutputChange(to: destination(elsewhere))
        engine.resolvePendingOutputChange(movingTranscripts: true)

        #expect(engine.pendingOutputChange == nil)
        #expect(engine.outputDirectory.path == elsewhere.path)
        let relocation = try #require(store.relocations.first)
        #expect(relocation.destination.path == elsewhere.path)
        #expect(relocation.transcripts.count == 1)
    }

    @Test func leavingThemBehindStillSwitchesFolder() {
        let store = SpyTranscriptStore(transcripts: [makeTranscript("a")])
        let engine = makeEngine(store: store, outputDirectoryPath: current.path)

        engine.requestOutputChange(to: destination(elsewhere))
        engine.resolvePendingOutputChange(movingTranscripts: false)

        #expect(engine.outputDirectory.path == elsewhere.path)
        #expect(store.relocations.isEmpty)
    }

    @Test func cancellingKeepsTheCurrentFolder() {
        let store = SpyTranscriptStore(transcripts: [makeTranscript("a")])
        let engine = makeEngine(store: store, outputDirectoryPath: current.path)

        engine.requestOutputChange(to: destination(elsewhere))
        engine.cancelPendingOutputChange()

        #expect(engine.pendingOutputChange == nil)
        #expect(engine.outputDirectory.path == current.path)
        #expect(store.relocations.isEmpty)
    }
}
