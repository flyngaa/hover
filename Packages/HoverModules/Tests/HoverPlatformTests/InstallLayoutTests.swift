import Foundation
import HoverCore
import Testing

@testable import HoverPlatform

/// Presence-based resolution of helpers and model data. Injected bundle and home
/// roots keep these tests off the real Application Support and the developer's
/// machine — no Homebrew, no model downloads, no network.
@Suite final class InstallLayoutTests {

    private let root: URL
    private let bundleRoot: URL
    private let home: URL
    private let helpersDir: URL
    private let appSupportModels: URL
    private let transcriptsModels: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hover-install-layout-\(UUID().uuidString)")
        bundleRoot = root.appendingPathComponent("Hover.app")
        home = root.appendingPathComponent("Home")
        helpersDir =
            bundleRoot
            .appendingPathComponent("Contents")
            .appendingPathComponent("Helpers")
        appSupportModels =
            home
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Hover")
            .appendingPathComponent("models")
        transcriptsModels =
            home
            .appendingPathComponent("Documents")
            .appendingPathComponent("Transcripts")
            .appendingPathComponent("models")

        for dir in [appSupportModels, transcriptsModels] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func resolve() throws -> InstallLayout {
        try InstallLayout.resolve(bundleRoot: bundleRoot, homeDirectory: home)
    }

    private func placeExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: Data())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
    }

    private func placeFile(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }

    private var bundledWhisper: URL {
        helpersDir.appendingPathComponent("whisper-cli")
    }

    private func placeCompleteBundledHelpers() throws {
        try placeExecutable(at: bundledWhisper)
    }

    @Test func emptyHelpersDirectoryFailsLayoutResolution() throws {
        try FileManager.default.createDirectory(at: helpersDir, withIntermediateDirectories: true)

        do {
            _ = try resolve()
            Issue.record("Expected incomplete shipped helpers to fail resolution")
        } catch let error as InstallLayout.ResolutionError {
            #expect(error == .incompleteShippedHelpers)
            #expect(error.localizedDescription.contains("Reinstall Hover"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func directoriesNamedLikeExecutablesAreIncompleteHelpers() throws {
        try FileManager.default.createDirectory(
            at: bundledWhisper,
            withIntermediateDirectories: true
        )

        #expect(throws: InstallLayout.ResolutionError.incompleteShippedHelpers) {
            try self.resolve()
        }
    }

    // MARK: - Complete Helpers present → shipped layout

    @Test func completeHelpersResolveToShippedLayout() throws {
        try placeCompleteBundledHelpers()

        let layout = try resolve()

        #expect(layout.whisperHelper.path == bundledWhisper.path)
        #expect(layout.modelsDirectory.path == appSupportModels.path)
    }

    // MARK: - Absent helpers → dev locations

    @Test func absentHelpersFallBackToDevLocations() throws {
        try placeFile(
            at: transcriptsModels.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")
        )

        let layout = try resolve()

        #expect(layout.whisperHelper.path == "/opt/homebrew/bin/whisper-cli")
        #expect(layout.modelsDirectory.path == transcriptsModels.path)
        #expect(layout.ggmlModelPresent)
    }

    // MARK: - Partial model directory → per-file presence

    @Test func missingWhisperModelReportsAbsence() throws {
        try placeCompleteBundledHelpers()

        let layout = try resolve()

        #expect(layout.modelsDirectory.path == appSupportModels.path)
        #expect(!layout.ggmlModelPresent)
    }

    // MARK: - App Support models never select shipped layout on their own

    @Test func populatedAppSupportModelsDoNotChangeDevLayout() throws {
        try placeFile(
            at: appSupportModels.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")
        )

        let layout = try resolve()

        #expect(layout.modelsDirectory.path == transcriptsModels.path)
        #expect(!layout.ggmlModelPresent)
        #expect(layout.whisperHelper.path == "/opt/homebrew/bin/whisper-cli")
    }

    // MARK: - Output Destination never moves model data

    @Test func modelDataLocationIgnoresOutputDestination() throws {
        try placeCompleteBundledHelpers()
        try placeFile(
            at: appSupportModels.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")
        )

        let layout = try resolve()

        // A Vault (or any other Output Destination) lives somewhere else entirely.
        // Model data must stay under Application Support / the transcripts models
        // folder — never follow the Output Destination.
        let vaultTranscripts =
            home
            .appendingPathComponent("Documents")
            .appendingPathComponent("MyVault")
            .appendingPathComponent("Transcripts")
        #expect(layout.modelsDirectory.path == appSupportModels.path)
        #expect(layout.modelsDirectory.path != vaultTranscripts.path)
        #expect(!layout.modelsDirectory.path.hasPrefix(vaultTranscripts.path))
    }

    @Test func devModelDataStaysUnderTranscriptsModelsNotAVault() throws {
        try placeFile(
            at: transcriptsModels.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")
        )

        let layout = try resolve()
        let vaultTranscripts =
            home
            .appendingPathComponent("Documents")
            .appendingPathComponent("MyVault")
            .appendingPathComponent("Transcripts")

        #expect(layout.modelsDirectory.path == transcriptsModels.path)
        #expect(layout.modelsDirectory.path != vaultTranscripts.path)
    }
}
