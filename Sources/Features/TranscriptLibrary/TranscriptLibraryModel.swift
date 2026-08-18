import Foundation
import HoverCore
import Observation

/// One folder the user can pick for saved transcripts.
struct OutputDestination: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case standard
        case vault
        case custom
    }

    let kind: Kind
    let name: String
    let directory: URL

    var id: String { directory.path }
}

struct PendingOutputDestinationChange: Identifiable, Sendable {
    let destination: OutputDestination
    let origin: URL
    let transcriptCount: Int

    var id: String { destination.id }
}

/// Owns transcript discovery, selection, searching, file actions, and output
/// destinations. It has no recording or model-setup dependencies.
@MainActor @Observable
final class TranscriptLibraryModel {
    private(set) var savedTranscripts: [SavedTranscript] = []
    private(set) var groups: [String] = []
    private(set) var lastRecordingTranscript: SavedTranscript?
    var selection = Selection()
    var pendingOutputChange: PendingOutputDestinationChange?
    private(set) var outputDirectory: URL
    private(set) var outputDirectoryAuthorizationRequest: URL?
    var presentedFailureMessage: String?

    @ObservationIgnored private let transcriptStore: any TranscriptStore
    @ObservationIgnored private let settings: any SettingsStore
    @ObservationIgnored private let vaultFinder: any VaultFinder
    @ObservationIgnored private let log: @Sendable (String) -> Void
    @ObservationIgnored private var securityScopedOutputDirectory: URL?

    init(
        transcriptStore: any TranscriptStore,
        settings: any SettingsStore,
        vaultFinder: any VaultFinder,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.transcriptStore = transcriptStore
        self.settings = settings
        self.vaultFinder = vaultFinder
        self.log = log
        let savedDirectory = Self.savedOutputDirectory(from: settings)
        do {
            try FileManager.default.createDirectory(
                at: savedDirectory,
                withIntermediateDirectories: true
            )
            outputDirectory = savedDirectory
        } catch {
            // Creation can itself be the first protected-folder operation. Ask
            // the user to select an accessible folder instead of falling into
            // an alert before the library even gets a chance to load.
            outputDirectory = savedDirectory
            outputDirectoryAuthorizationRequest = savedDirectory
        }
        reload()
    }

    static var defaultOutputDirectory: URL {
        RecordingOutput.defaultDirectory
    }

    static func savedOutputDirectory(from settings: any SettingsStore) -> URL {
        guard let path = settings.outputDirectoryPath else { return defaultOutputDirectory }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : defaultOutputDirectory
    }

    /// Whether the user has ever explicitly picked an Output Destination. `false`
    /// on a fresh install, when saves fall back to the default folder — the
    /// signal the first-run prompt uses to ask once instead of saving silently.
    var hasChosenOutputDestination: Bool {
        settings.outputDirectoryPath != nil
    }

    static func shortPath(_ url: URL) -> String {
        url.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: "~"
        )
    }

    var markedTranscriptIDs: Set<String> {
        get { selection.markedIDs }
        set { selection.markedIDs = newValue }
    }

    var selectionAnchorID: String? {
        get { selection.anchorID }
        set { selection.anchorID = newValue }
    }

    var markedTranscripts: [SavedTranscript] {
        savedTranscripts.filter { selection.isMarked($0.id) }
    }

    var primaryMarkedTranscript: SavedTranscript? {
        guard let id = selection.primaryID else { return nil }
        return savedTranscripts.first { $0.id == id }
    }

    var availableVaults: [ObsidianVault] { vaultFinder.discoverVaults() }

    var outputDestinations: [OutputDestination] {
        var result = [
            OutputDestination(
                kind: .standard,
                name: Self.defaultOutputDirectory.lastPathComponent,
                directory: Self.defaultOutputDirectory
            )
        ]
        result += availableVaults.map {
            OutputDestination(kind: .vault, name: $0.name, directory: $0.transcriptsFolder)
        }
        if !result.contains(where: { $0.directory.path == outputDirectory.path }) {
            result.append(
                OutputDestination(
                    kind: .custom,
                    name: outputDirectory.lastPathComponent,
                    directory: outputDirectory
                ))
        }
        return result
    }

    var currentOutputDestination: OutputDestination {
        outputDestinations.first { $0.directory.path == outputDirectory.path }
            ?? OutputDestination(
                kind: .custom,
                name: outputDirectory.lastPathComponent,
                directory: outputDirectory
            )
    }

    var outputDirectoryLabel: String { Self.shortPath(outputDirectory) }

    func reload() {
        do {
            let library = try transcriptStore.load(in: outputDirectory)
            savedTranscripts = library.transcripts
            groups = library.groups
            outputDirectoryAuthorizationRequest = nil
            presentedFailureMessage = nil
        } catch let error as TranscriptStoreError {
            if case .unreadableDirectory = error {
                // A path in Documents, iCloud Drive, OneDrive, or another
                // protected location may need an explicit user selection. Let
                // the view present macOS's folder picker instead of showing a
                // dead-end filesystem error.
                savedTranscripts = []
                groups = []
                outputDirectoryAuthorizationRequest = outputDirectory
                presentedFailureMessage = nil
            } else {
                present(error)
            }
        } catch {
            present(error)
        }
    }

    /// Retry an unreadable Output Destination after the user selects a folder
    /// in macOS's authorization picker. Selecting a different folder is also a
    /// valid recovery and makes that folder the new destination.
    func authorizeOutputDirectory(_ directory: URL) {
        let startedSecurityScope = directory.startAccessingSecurityScopedResource()
        outputDirectoryAuthorizationRequest = nil
        setOutputDirectory(directory)
        if outputDirectoryAuthorizationRequest == nil {
            securityScopedOutputDirectory?.stopAccessingSecurityScopedResource()
            securityScopedOutputDirectory = startedSecurityScope ? directory : nil
        } else if startedSecurityScope {
            directory.stopAccessingSecurityScopedResource()
        }
    }

    func cancelOutputDirectoryAuthorization() {
        outputDirectoryAuthorizationRequest = nil
    }

    func recordingDidFinish(_ result: RecordingResult) -> SavedTranscript? {
        reload()
        guard let path = result.path else {
            lastRecordingTranscript = nil
            return nil
        }
        let target = path.resolvingSymlinksInPath()
        guard
            let loaded = savedTranscripts.first(where: {
                $0.path.resolvingSymlinksInPath() == target
            })
        else {
            lastRecordingTranscript = nil
            return nil
        }
        // Keep the definitive session URL. FileManager may canonicalize `/var`
        // to `/private/var` while listing, even though both identify this file.
        lastRecordingTranscript = SavedTranscript(
            id: loaded.id,
            name: loaded.name,
            date: loaded.date,
            path: path,
            group: loaded.group
        )
        // The recording that just finished is what the user is looking at, so it
        // becomes the marked transcript — and the sidebar can then move off it.
        selection = Selection(markedIDs: [loaded.id], anchorID: loaded.id)
        return lastRecordingTranscript
    }

    func rename(_ transcript: SavedTranscript, to newName: String) {
        moveOnDisk(transcript) { try transcriptStore.rename($0, to: newName) }
    }

    func move(_ transcript: SavedTranscript, toGroup group: String?) {
        moveOnDisk(transcript) {
            try transcriptStore.move($0, toGroup: group, in: outputDirectory)
        }
    }

    private func moveOnDisk(
        _ transcript: SavedTranscript,
        using fileMove: (SavedTranscript) throws -> SavedTranscript
    ) {
        do {
            let updated = try fileMove(transcript)
            guard updated != transcript else { return }
            if let index = savedTranscripts.firstIndex(of: transcript) {
                savedTranscripts[index] = updated
            }
            if markedTranscriptIDs.contains(transcript.id) {
                replaceMarkedID(transcript.id, with: updated.id)
            }
            if lastRecordingTranscript == transcript { lastRecordingTranscript = updated }
            groups = Array(Set(savedTranscripts.compactMap(\.group))).sorted()
        } catch {
            present(error)
        }
    }

    func searchHits(for query: String) async -> Set<String> {
        let transcripts = savedTranscripts
        let store = transcriptStore
        return await Task.detached(priority: .userInitiated) {
            Set(transcripts.filter { store.matches($0, query: query) }.map(\.id))
        }.value
    }

    func loadTranscriptContent(_ transcript: SavedTranscript) -> String {
        do {
            return try transcriptStore.content(of: transcript)
        } catch {
            present(error)
            return ""
        }
    }

    func deleteTranscript(_ transcript: SavedTranscript) {
        do {
            try transcriptStore.delete(transcript)
            unmarkDeleted(transcript.id)
            if lastRecordingTranscript == transcript { lastRecordingTranscript = nil }
            savedTranscripts.removeAll { $0.id == transcript.id }
        } catch {
            present(error)
        }
    }

    func clearMarkedTranscripts() { selection.clear() }
    func markAll(ids: [String]) { selection.markAll(ids) }
    func toggleMark(_ id: String) { selection.toggle(id) }
    func markRange(to id: String, in orderedIDs: [String]) {
        selection.markRange(to: id, in: orderedIDs)
    }
    func replaceMarkedID(_ oldID: String, with newID: String) {
        selection.replace(oldID, with: newID)
    }
    func unmarkDeleted(_ id: String) { selection.unmarkDeleted(id) }

    func combinedMarkedContent(separator: String = "\n\n") -> String {
        markedTranscripts
            .map { loadTranscriptContent($0) }
            .filter { !$0.isEmpty }
            .joined(separator: separator)
    }

    func deleteMarkedTranscripts() {
        for transcript in markedTranscripts { deleteTranscript(transcript) }
        clearMarkedTranscripts()
    }

    func requestOutputChange(to destination: OutputDestination) {
        let origin = outputDirectory
        guard destination.directory.path != origin.path else { return }
        guard !savedTranscripts.isEmpty else {
            do {
                try apply(destination)
            } catch {
                present(error)
            }
            return
        }
        pendingOutputChange = PendingOutputDestinationChange(
            destination: destination,
            origin: origin,
            transcriptCount: savedTranscripts.count
        )
    }

    func requestOutputChange(toFolder url: URL) {
        requestOutputChange(
            to: OutputDestination(
                kind: .custom,
                name: url.lastPathComponent,
                directory: url
            ))
    }

    @discardableResult
    func resolvePendingOutputChange(movingTranscripts: Bool) -> String? {
        guard let pending = pendingOutputChange else { return nil }
        pendingOutputChange = nil
        var warning: String?
        if movingTranscripts {
            let transcripts = savedTranscripts
            do {
                try FileManager.default.createDirectory(
                    at: pending.destination.directory,
                    withIntermediateDirectories: true
                )
            } catch {
                present(
                    TranscriptStoreError.createDirectoryFailed(
                        diagnostic: error.localizedDescription
                    ))
                return presentedFailureMessage
            }
            let report = transcriptStore.relocate(
                transcripts,
                to: pending.destination.directory
            )
            log("Moved \(report.moved.count) of \(transcripts.count) transcript(s)")
            if !report.failures.isEmpty {
                warning =
                    "Moved \(report.moved.count) of \(transcripts.count) transcripts. "
                    + "The rest are still in \(Self.shortPath(pending.origin))."
            }
        }
        do {
            try apply(pending.destination)
        } catch {
            present(error)
            return presentedFailureMessage
        }
        return warning
    }

    func cancelPendingOutputChange() { pendingOutputChange = nil }

    func setOutputDirectory(_ directory: URL) {
        do {
            try apply(
                OutputDestination(
                    kind: .custom,
                    name: directory.lastPathComponent,
                    directory: directory
                ))
        } catch {
            present(error)
        }
    }

    private func apply(_ destination: OutputDestination) throws {
        do {
            try FileManager.default.createDirectory(
                at: destination.directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw TranscriptStoreError.createDirectoryFailed(diagnostic: error.localizedDescription)
        }
        outputDirectory = destination.directory
        settings.outputDirectoryPath = outputDirectory.path
        clearMarkedTranscripts()
        lastRecordingTranscript = nil
        reload()
    }

    private func present(_ error: Error) {
        presentedFailureMessage = error.localizedDescription
    }
}
