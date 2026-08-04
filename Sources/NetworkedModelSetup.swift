import Foundation

/// ``ModelSetup`` that fetches missing model files from pinned upstream URLs
/// into a models directory (Application Support on the release path).
///
/// Verification for v1 is a size check against ``ModelArtifact/expectedSize``.
/// The segmentation artifact arrives as a `.tar.bz2` and is extracted so the
/// ONNX file lands at the path Install Layout expects. Never downloads
/// executables — model data only.
final class NetworkedModelSetup: ModelSetup {

    private let modelsDirectory: URL
    private let fileManager: FileManager
    private let session: URLSession

    init(
        modelsDirectory: URL,
        fileManager: FileManager = .default,
        session: URLSession = .shared
    ) {
        self.modelsDirectory = modelsDirectory
        self.fileManager = fileManager
        self.session = session
    }

    var isComplete: Bool {
        ModelArtifact.allCases.allSatisfy { isPresent($0) }
    }

    func fetchMissing(progress: @escaping @Sendable (Double) -> Void) async throws {
        let missing = ModelArtifact.allCases.filter { !isPresent($0) }
        guard !missing.isEmpty else {
            progress(1)
            return
        }

        // Weight overall progress by each artifact's final on-disk size so a
        // Retry that only needs the last file starts near the end, not at zero.
        let totalBytes = ModelArtifact.totalExpectedSize
        let alreadyPresent = ModelArtifact.allCases
            .filter { isPresent($0) }
            .reduce(Int64(0)) { $0 + $1.expectedSize }
        // Box the running total so progress callbacks (which are @Sendable) can
        // read it without capturing a mutable local across await boundaries.
        let completed = CompletedBytes(alreadyPresent)
        progress(Double(completed.value) / Double(totalBytes))

        try fileManager.createDirectory(
            at: modelsDirectory,
            withIntermediateDirectories: true
        )

        for artifact in missing {
            let base = completed.value
            try await fetch(artifact) { artifactBytes in
                let fraction = Double(base + artifactBytes) / Double(totalBytes)
                progress(min(1, max(0, fraction)))
            }
            completed.value += artifact.expectedSize
            progress(Double(completed.value) / Double(totalBytes))
        }

        guard isComplete else {
            throw ModelSetupError.verificationFailed(
                "Downloaded model data failed the size check."
            )
        }
    }

    // MARK: - Presence

    private func isPresent(_ artifact: ModelArtifact) -> Bool {
        let url = modelsDirectory.appendingPathComponent(artifact.relativePath)
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber
        else { return false }
        return size.int64Value == artifact.expectedSize
    }

    // MARK: - Fetch

    private func fetch(
        _ artifact: ModelArtifact,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        switch artifact {
        case .ggml, .embedding:
            let destination = modelsDirectory.appendingPathComponent(artifact.relativePath)
            try await downloadFile(
                from: artifact.sourceURL,
                to: destination,
                expectedSize: artifact.expectedSize,
                progress: progress
            )
        case .segmentation:
            try await fetchSegmentationArchive(progress: progress)
        }
    }

    /// Download the k2-fsa segmentation tarball and extract it so
    /// `sherpa-onnx-pyannote-segmentation-3-0/model.onnx` is in place.
    private func fetchSegmentationArchive(
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let tempArchive = fileManager.temporaryDirectory
            .appendingPathComponent("hover-seg-\(UUID().uuidString).tar.bz2")
        defer { try? fileManager.removeItem(at: tempArchive) }

        // Archive progress is mapped onto the final ONNX size so the overall
        // bar still sums to the three on-disk artifacts.
        try await downloadFile(
            from: ModelArtifact.segmentation.sourceURL,
            to: tempArchive,
            expectedSize: ModelArtifact.segmentationArchiveSize,
            progress: { archiveBytes in
                let mapped = Int64(
                    Double(archiveBytes) / Double(ModelArtifact.segmentationArchiveSize)
                        * Double(ModelArtifact.segmentation.expectedSize)
                )
                progress(mapped)
            }
        )

        try extractTarBzip2(tempArchive, into: modelsDirectory)

        guard isPresent(.segmentation) else {
            throw ModelSetupError.verificationFailed(
                "Downloaded segmentation model failed the size check."
            )
        }
    }

    private func downloadFile(
        from remote: URL,
        to destination: URL,
        expectedSize: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        let downloaded = try await DownloadSession.download(
            from: remote,
            using: session,
            progress: progress
        )
        defer { try? fileManager.removeItem(at: downloaded) }

        let size = (try? fileManager.attributesOfItem(atPath: downloaded.path)[.size] as? NSNumber)?
            .int64Value ?? -1
        guard size == expectedSize else {
            throw ModelSetupError.verificationFailed(
                "Downloaded file failed the size check."
            )
        }

        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: downloaded, to: destination)
    }

    private func extractTarBzip2(_ archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", archive.path, "-C", directory.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw ModelSetupError.fetchFailed("Could not extract the segmentation model archive.")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ModelSetupError.fetchFailed("Could not extract the segmentation model archive.")
        }
    }
}

/// Mutable byte counter shared with @Sendable progress callbacks.
private final class CompletedBytes: @unchecked Sendable {
    var value: Int64
    init(_ value: Int64) { self.value = value }
}

// MARK: - URLSession download with progress

/// Thin wrapper so production can report overall progress without the engine
/// knowing about URLSession delegates.
private enum DownloadSession {
    static func download(
        from remote: URL,
        using session: URLSession,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL {
        let delegate = ProgressDownloadDelegate(progress: progress)
        let config = session.configuration
        let tracked = URLSession(
            configuration: config,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { tracked.finishTasksAndInvalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            delegate.finish = { result in
                continuation.resume(with: result)
            }
            let task = tracked.downloadTask(with: remote)
            task.resume()
        }
    }
}

private final class ProgressDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let progress: @Sendable (Int64) -> Void
    var finish: ((Result<URL, Error>) -> Void)?
    private var finished = false

    init(progress: @escaping @Sendable (Int64) -> Void) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progress(totalBytesWritten)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            complete(.failure(ModelSetupError.fetchFailed(
                "Download failed (HTTP \(http.statusCode))."
            )))
            return
        }

        // The temporary download location is deleted when this method returns,
        // so move it somewhere we own first.
        let owned = FileManager.default.temporaryDirectory
            .appendingPathComponent("hover-dl-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: owned)
            complete(.success(owned))
        } catch {
            complete(.failure(ModelSetupError.fetchFailed(
                "Could not save the downloaded file."
            )))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            complete(.failure(ModelSetupError.fetchFailed(error.localizedDescription)))
        }
    }

    private func complete(_ result: Result<URL, Error>) {
        guard !finished else { return }
        finished = true
        finish?(result)
    }
}

// MARK: - Artifact sources

extension ModelArtifact {
    /// Byte size of the upstream `.tar.bz2` that contains the segmentation ONNX.
    static let segmentationArchiveSize: Int64 = 6_958_444

    var sourceURL: URL {
        switch self {
        case .ggml:
            // Pinned to the HF revision that serves the 574041195-byte q5_0 file
            // (not `main`, which can move).
            return URL(string:
                "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin"
            )!
        case .segmentation:
            return URL(string:
                "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2"
            )!
        case .embedding:
            return URL(string:
                "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/nemo_en_titanet_small.onnx"
            )!
        }
    }
}

// MARK: - Errors

enum ModelSetupError: Error, LocalizedError {
    case fetchFailed(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .fetchFailed(let message), .verificationFailed(let message):
            return message
        }
    }
}
