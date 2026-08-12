import Foundation
import HoverCore
import Testing

@testable import HoverPlatform

/// Availability means "this Mac can tag speakers" — native helper + both models,
/// or the dev venv + script + both models. Missing either path still reports
/// unavailable so a recording is saved unlabeled rather than failing silently.
@Suite final class SpeakerTaggingAvailabilityTests {

    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hover-speaker-avail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func placeExecutable(named name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
        return url
    }

    private func placeFile(named name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    @Test func nativeHelperPlusBothModelsIsAvailableWithoutScript() throws {
        let helper = try placeExecutable(named: "sherpa-onnx-offline-speaker-diarization")
        let seg = try placeFile(named: "seg/model.onnx")
        let emb = try placeFile(named: "emb.onnx")

        #expect(
            LocalSpeakerDiarizer.isAvailable(
                helper: helper,
                segmentationModel: seg,
                embeddingModel: emb,
                scriptPath: nil
            )
        )
    }

    @Test func venvPythonNeedsTheScriptAsWellAsBothModels() throws {
        let python = try placeExecutable(named: "python")
        let seg = try placeFile(named: "seg/model.onnx")
        let emb = try placeFile(named: "emb.onnx")

        #expect(
            !LocalSpeakerDiarizer.isAvailable(
                helper: python,
                segmentationModel: seg,
                embeddingModel: emb,
                scriptPath: nil
            )
        )
        #expect(
            LocalSpeakerDiarizer.isAvailable(
                helper: python,
                segmentationModel: seg,
                embeddingModel: emb,
                scriptPath: "/tmp/diarize.py"
            )
        )
    }

    @Test func missingModelsMeansUnavailableEvenWithAHelper() throws {
        let helper = try placeExecutable(named: "sherpa-onnx-offline-speaker-diarization")
        let seg = root.appendingPathComponent("missing-seg.onnx")
        let emb = root.appendingPathComponent("missing-emb.onnx")

        #expect(
            !LocalSpeakerDiarizer.isAvailable(
                helper: helper,
                segmentationModel: seg,
                embeddingModel: emb,
                scriptPath: nil
            )
        )
    }
}
