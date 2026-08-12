import Foundation
import HoverCore
import Testing

@testable import HoverPlatform

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Double] = []

    var values: [Double] {
        get { lock.withLock { storedValues } }
        set { lock.withLock { storedValues = newValue } }
    }

    func append(_ value: Double) {
        lock.withLock { storedValues.append(value) }
    }
}

/// Presence and size-check behaviour of the production Model Setup, exercised
/// against a temp directory — no network.
@Suite @MainActor final class NetworkedModelSetupTests {

    private let root: URL
    private let models: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hover-model-setup-\(UUID().uuidString)")
        models = root.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func setup() -> NetworkedModelSetup {
        NetworkedModelSetup(modelsDirectory: models)
    }

    private func write(_ artifact: ModelArtifact, size: Int64) throws {
        let url = models.appendingPathComponent(artifact.relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Truncate to the expected length without allocating the bytes in RAM —
        // the GGML artifact is ~547 MiB.
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
    }

    @Test func emptyDirectoryIsIncomplete() {
        #expect(!setup().isComplete)
    }

    @Test func allThreeCorrectSizesAreComplete() throws {
        for artifact in ModelArtifact.allCases {
            try write(artifact, size: artifact.expectedSize)
        }
        #expect(setup().isComplete)
    }

    @Test func wrongSizeCountsAsMissing() throws {
        try write(.ggml, size: ModelArtifact.ggml.expectedSize)
        try write(.segmentation, size: ModelArtifact.segmentation.expectedSize)
        try write(.embedding, size: ModelArtifact.embedding.expectedSize - 1)

        #expect(!setup().isComplete)
    }

    @Test func fetchMissingWithNothingMissingReportsComplete() async throws {
        for artifact in ModelArtifact.allCases {
            try write(artifact, size: artifact.expectedSize)
        }
        let modelSetup = setup()
        let fractions = ProgressLog()
        for try await fraction in modelSetup.fetchMissing() {
            fractions.append(fraction)
        }
        #expect(modelSetup.isComplete)
        #expect(fractions.values.last == 1)
    }
}
