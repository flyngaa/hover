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

    private var bundledSpeakerTagging: URL {
        helpersDir.appendingPathComponent("sherpa-onnx-offline-speaker-diarization")
    }

    private var bundledONNXRuntime: URL {
        bundleRoot.appendingPathComponent("Contents/Frameworks/libonnxruntime.1.27.0.dylib")
    }

    private var bundledONNXRuntimeInHelpers: URL {
        helpersDir.appendingPathComponent("libonnxruntime.1.27.0.dylib")
    }

    private func placeCompleteBundledHelpers() throws {
        try placeExecutable(at: bundledWhisper)
        try placeExecutable(at: bundledSpeakerTagging)
        try placeFile(at: bundledONNXRuntime)
    }

    @Test func incompleteHelpersDirectoryFailsLayoutResolution() throws {
        try placeExecutable(at: bundledWhisper)
        try placeExecutable(at: bundledSpeakerTagging)

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
        try FileManager.default.createDirectory(
            at: bundledSpeakerTagging,
            withIntermediateDirectories: true
        )
        try placeFile(at: bundledONNXRuntime)

        #expect(throws: InstallLayout.ResolutionError.incompleteShippedHelpers) {
            try self.resolve()
        }
    }

    // MARK: - Complete Helpers present → shipped layout

    @Test func completeHelpersResolveToShippedLayout() throws {
        try placeCompleteBundledHelpers()

        let layout = try resolve()

        #expect(layout.whisperHelper.path == bundledWhisper.path)
        #expect(layout.speakerTaggingHelper.path == bundledSpeakerTagging.path)
        #expect(layout.modelsDirectory.path == appSupportModels.path)
    }

    @Test func completeLocalHelperPayloadResolvesToShippedLayout() throws {
        try placeExecutable(at: bundledWhisper)
        try placeExecutable(at: bundledSpeakerTagging)
        try placeFile(at: bundledONNXRuntimeInHelpers)

        let layout = try resolve()

        #expect(layout.whisperHelper.path == bundledWhisper.path)
        #expect(layout.speakerTaggingHelper.path == bundledSpeakerTagging.path)
        #expect(layout.modelsDirectory.path == appSupportModels.path)
    }

    // MARK: - Absent helpers → dev locations

    @Test func absentHelpersFallBackToDevLocations() throws {
        // Populate the transcripts models folder the way a local build does, so
        // the fallback has somewhere real to point — without claiming App Support.
        try placeFile(
            at: transcriptsModels.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")
        )
        try placeExecutable(
            at:
                transcriptsModels
                .appendingPathComponent("diar-venv")
                .appendingPathComponent("bin")
                .appendingPathComponent("python")
        )

        let layout = try resolve()

        #expect(layout.whisperHelper.path == "/opt/homebrew/bin/whisper-cli")
        #expect(
            layout.speakerTaggingHelper.path
                == transcriptsModels
                .appendingPathComponent("diar-venv")
                .appendingPathComponent("bin")
                .appendingPathComponent("python").path
        )
        #expect(layout.modelsDirectory.path == transcriptsModels.path)
    }

    // MARK: - Partial model directory → per-file presence

    @Test func partialModelDirectoryReportsPresencePerFile() throws {
        try placeCompleteBundledHelpers()
        // Only the GGML model is present; the two ONNX files are missing.
        try placeFile(
            at: appSupportModels.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")
        )

        let layout = try resolve()

        #expect(layout.modelsDirectory.path == appSupportModels.path)
        #expect(layout.ggmlModelPresent)
        #expect(!layout.segmentationModelPresent)
        #expect(!layout.embeddingModelPresent)
    }

    // MARK: - App Support models never select shipped layout on their own

    @Test func populatedAppSupportModelsDoNotChangeDevLayout() throws {
        try placeFile(
            at: appSupportModels.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")
        )
        try placeFile(
            at: transcriptsModels.appendingPathComponent("nemo_en_titanet_small.onnx")
        )

        let layout = try resolve()

        #expect(layout.modelsDirectory.path == transcriptsModels.path)
        #expect(!layout.ggmlModelPresent)
        #expect(layout.embeddingModelPresent)
        #expect(layout.whisperHelper.path == "/opt/homebrew/bin/whisper-cli")
        #expect(
            layout.speakerTaggingHelper.path
                == transcriptsModels.appendingPathComponent("diar-venv/bin/python").path
        )
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
