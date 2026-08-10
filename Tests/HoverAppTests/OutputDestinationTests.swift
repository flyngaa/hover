import Foundation
import HoverCore
import HoverPlatform
import Testing

@testable import HoverApp

/// Transcripts live in exactly one folder. These tests pin down how that folder
/// is chosen — including that switching folders never silently abandons files.
///
/// A `final class` suite so each test gets fresh temp directories via `init`,
/// cleaned up in `deinit`. Real directories are needed because the engine falls
/// back to the default folder when a saved path no longer exists.
@Suite @MainActor final class OutputDestinationTests {

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
        private let lock = NSLock()
        private var storedLibrary: TranscriptLibrary
        private var storedRelocations: [(transcripts: [SavedTranscript], destination: URL)] = []
        private let deleteFails: Bool

        var library: TranscriptLibrary {
            get { lock.withLock { storedLibrary } }
            set { lock.withLock { storedLibrary = newValue } }
        }
        var relocations: [(transcripts: [SavedTranscript], destination: URL)] {
            lock.withLock { storedRelocations }
        }

        init(transcripts: [SavedTranscript] = [], deleteFails: Bool = false) {
            storedLibrary = TranscriptLibrary(transcripts: transcripts, groups: [])
            self.deleteFails = deleteFails
        }

        func availableRecordingDestination(
            for date: Date,
            in directory: URL
        ) -> (title: String, url: URL) {
            let title = TranscriptDocument.title(for: date)
            return (title, directory.appendingPathComponent(title).appendingPathExtension("md"))
        }

        func load(in directory: URL) throws -> TranscriptLibrary { library }
        func rename(_ transcript: SavedTranscript, to newName: String) throws -> SavedTranscript {
            transcript
        }
        func move(
            _ transcript: SavedTranscript,
            toGroup group: String?,
            in directory: URL
        ) throws -> SavedTranscript {
            transcript
        }
        func relocate(
            _ transcripts: [SavedTranscript],
            to directory: URL
        ) -> TranscriptRelocationReport {
            lock.withLock { storedRelocations.append((transcripts, directory)) }
            return TranscriptRelocationReport(moved: transcripts)
        }
        func delete(_ transcript: SavedTranscript) throws {
            if deleteFails {
                throw TranscriptStoreError.deleteFailed(diagnostic: "simulated")
            }
        }
        func matches(_ transcript: SavedTranscript, query: String) -> Bool { false }
        func content(of transcript: SavedTranscript) throws -> String { "" }
        func write(title: String, body: String, to url: URL) throws {}
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
    ) -> TranscriptLibraryModel {
        TranscriptLibraryModel(
            transcriptStore: store,
            settings: InMemorySettings(outputDirectoryPath: outputDirectoryPath),
            vaultFinder: FakeVaultFinder(paths: vaultPaths)
        )
    }

    private func destination(_ url: URL) -> OutputDestination {
        OutputDestination(kind: .custom, name: url.lastPathComponent, directory: url)
    }

    // MARK: - What's on offer

    @Test func standardFolderIsTheDefaultChoice() {
        let engine = makeEngine()
        #expect(engine.currentOutputDestination.kind == .standard)
        #expect(engine.outputDirectory == TranscriptLibraryModel.defaultOutputDirectory)
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

    /// The folder has to be observable, or the toolbar and the menu's tick go on
    /// naming the old one after a switch. This regressed once already: the folder
    /// was computed from the settings store, which the engine deliberately hides
    /// from observation, so nothing SwiftUI could see ever changed.
    @Test func switchingFolderTellsObservers() {
        let engine = makeEngine(outputDirectoryPath: current.path)

        let flag = ChangeFlag()
        withObservationTracking {
            _ = engine.outputDirectory
        } onChange: {
            flag.sawChange = true
        }

        engine.requestOutputChange(to: destination(elsewhere))
        #expect(flag.sawChange)
    }

    /// `onChange` is a `@Sendable` closure, so it can't set a local variable.
    private final class ChangeFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var storedValue = false
        var sawChange: Bool {
            get { lock.withLock { storedValue } }
            set { lock.withLock { storedValue = newValue } }
        }
    }

    @Test func switchingToTheSameFolderDoesNothing() {
        let store = SpyTranscriptStore(transcripts: [makeTranscript("a")])
        let engine = makeEngine(store: store, outputDirectoryPath: current.path)

        engine.requestOutputChange(to: destination(current))
        #expect(engine.pendingOutputChange == nil)
    }

    @Test func switchingIsBlockedWhileRecording() async {
        let library = makeEngine(outputDirectoryPath: current.path)
        let recording = RecordingModel(
            transcriber: FakeTranscriber(result: ""),
            audioCapture: FakeAudioCapture(),
            transcriptStore: FakeTranscriptStore(),
            settings: InMemorySettings(),
            permissions: FakeRecordingPermissions(),
            speakerDiarizer: FakeSpeakerDiarizer(turns: [])
        )
        let appModel = AppModel(
            recording: recording,
            transcriptLibrary: library,
            modelSetup: ModelSetupController(modelSetup: FakeModelSetup(isComplete: true))
        )
        await appModel.startRecording()

        appModel.requestOutputChange(to: destination(elsewhere))
        #expect(library.pendingOutputChange == nil)
        #expect(library.outputDirectory.path == current.path)
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

    @Test func failedDeleteKeepsTranscriptVisibleAndSelected() {
        let transcript = makeTranscript("keep")
        let store = SpyTranscriptStore(transcripts: [transcript], deleteFails: true)
        let engine = makeEngine(store: store, outputDirectoryPath: current.path)
        engine.toggleMark(transcript.id)

        engine.deleteTranscript(transcript)

        #expect(engine.savedTranscripts == [transcript])
        #expect(engine.markedTranscriptIDs == [transcript.id])
        #expect(engine.presentedFailureMessage != nil)
    }

    @Test func invalidDestinationLeavesOldSelectionAndSettingUntouched() throws {
        let settings = InMemorySettings(outputDirectoryPath: current.path)
        let blocked = current.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: blocked)
        let engine = TranscriptLibraryModel(
            transcriptStore: SpyTranscriptStore(),
            settings: settings,
            vaultFinder: FakeVaultFinder()
        )

        engine.requestOutputChange(to: destination(blocked))

        #expect(engine.outputDirectory.path == current.path)
        #expect(settings.outputDirectoryPath == current.path)
        #expect(engine.presentedFailureMessage != nil)
    }
}
