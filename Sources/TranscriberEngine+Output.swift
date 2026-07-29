import Foundation
import AppKit

/// One place the user can pick for saved transcripts. Transcripts live in
/// exactly one of these at a time — Hover never keeps a second copy elsewhere.
struct OutputDestination: Identifiable, Hashable {

    enum Kind: Hashable {
        /// `~/Documents/Transcripts`, used until the user picks something else.
        case standard
        /// The Transcripts subfolder of an Obsidian vault.
        case vault
        /// Any other folder the user chose themselves.
        case custom
    }

    let kind: Kind
    /// Short name for the menu and the toolbar button (e.g. a vault's name).
    let name: String
    /// The folder transcripts are actually written to.
    let directory: URL

    var id: String { directory.path }
}

/// A folder change that is waiting on the user, because applying it would leave
/// transcripts behind in the old folder.
struct PendingOutputChange: Identifiable {
    let destination: OutputDestination
    let origin: URL
    /// How many transcripts are currently in the old folder.
    let transcriptCount: Int

    var id: String { destination.id }
}

extension TranscriberEngine {

    // MARK: - Well-known folders

    static var defaultOutputDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
            .appendingPathComponent("Transcripts")
    }

    static var modelsDirectory: URL {
        let dir = defaultOutputDirectory.appendingPathComponent("models")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - The current folder

    /// The single folder transcripts are saved to. Setting it only repoints the
    /// app; moving existing files is a separate, explicit step. Prefer
    /// ``requestOutputChange(to:)`` from the UI so the user is offered the move.
    var outputDirectory: URL {
        get {
            if let path = settings.outputDirectoryPath {
                let url = URL(fileURLWithPath: path, isDirectory: true)
                if FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
            }
            return Self.defaultOutputDirectory
        }
        set {
            settings.outputDirectoryPath = newValue.path
            try? FileManager.default.createDirectory(at: newValue, withIntermediateDirectories: true)
            loadSavedTranscripts()
        }
    }

    var outputDirectoryLabel: String { Self.shortPath(outputDirectory) }

    /// Path with the home folder collapsed to `~`, for display.
    static func shortPath(_ url: URL) -> String {
        url.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: "~"
        )
    }

    // MARK: - Choosable destinations

    var availableVaults: [ObsidianVault] { vaultFinder.discoverVaults() }

    /// Everything offered in the output menu: the standard folder, a slot for
    /// each Obsidian vault, and the user's own folder if they've picked one that
    /// is neither.
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

        let current = outputDirectory
        if !result.contains(where: { $0.directory.path == current.path }) {
            result.append(
                OutputDestination(kind: .custom, name: current.lastPathComponent, directory: current)
            )
        }
        return result
    }

    /// The destination currently in use, so the menu can tick it and the toolbar
    /// button can name it.
    var currentOutputDestination: OutputDestination {
        let current = outputDirectory
        return outputDestinations.first { $0.directory.path == current.path }
            ?? OutputDestination(kind: .custom, name: current.lastPathComponent, directory: current)
    }

    // MARK: - Changing folder

    /// Start switching to `destination`. If transcripts are sitting in the old
    /// folder, this parks the change in ``pendingOutputChange`` so the UI can ask
    /// whether to bring them along; otherwise it applies immediately.
    func requestOutputChange(to destination: OutputDestination) {
        guard !isRecording else { return }
        let origin = outputDirectory
        guard destination.directory.path != origin.path else { return }

        guard !savedTranscripts.isEmpty else {
            apply(destination)
            return
        }

        pendingOutputChange = PendingOutputChange(
            destination: destination,
            origin: origin,
            transcriptCount: savedTranscripts.count
        )
    }

    /// Convenience for a folder chosen from the open panel.
    func requestOutputChange(toFolder url: URL) {
        requestOutputChange(
            to: OutputDestination(kind: .custom, name: url.lastPathComponent, directory: url)
        )
    }

    /// Resolve a parked change. `movingTranscripts` moves the old folder's
    /// transcripts (keeping their groups) into the new one first.
    func resolvePendingOutputChange(movingTranscripts: Bool) {
        guard let pending = pendingOutputChange else { return }
        pendingOutputChange = nil

        if movingTranscripts {
            let transcripts = savedTranscripts
            try? FileManager.default.createDirectory(
                at: pending.destination.directory, withIntermediateDirectories: true
            )
            let moved = transcriptStore.relocate(transcripts, to: pending.destination.directory)
            log("Moved \(moved) of \(transcripts.count) transcript(s) to \(pending.destination.directory.path)")
            if moved < transcripts.count {
                authError = "Moved \(moved) of \(transcripts.count) transcripts. "
                    + "The rest are still in \(Self.shortPath(pending.origin))."
            }
        }

        apply(pending.destination)
    }

    func cancelPendingOutputChange() {
        pendingOutputChange = nil
    }

    private func apply(_ destination: OutputDestination) {
        outputDirectory = destination.directory
        // Marks and the last-recording pointer refer to files in the old folder.
        clearMarkedTranscripts()
        lastRecordingTranscript = nil
        log("Saving transcripts to \(destination.directory.path)")
    }

    // MARK: - Finder

    func revealOutputDirectory() {
        let directory = outputDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path)
    }
}
