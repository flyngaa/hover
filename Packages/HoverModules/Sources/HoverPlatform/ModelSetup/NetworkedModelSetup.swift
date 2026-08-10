import Foundation
import HoverCore

/// ``ModelSetup`` that fetches missing model files from pinned upstream URLs
/// into a models directory (Application Support on the release path).
///
/// Verification for v1 is a size check against ``ModelArtifact/expectedSize``.
/// The segmentation artifact arrives as a `.tar.bz2` and is extracted so the
/// ONNX file lands at the path Install Layout expects. Never downloads
/// executables — model data only.
public final class NetworkedModelSetup: ModelSetup {

    private let modelsDirectory: URL
    private let fileManager: FileManager
    private let session: URLSession
    private let processRunner: any ProcessRunning

    public init(
        modelsDirectory: URL,
        fileManager: FileManager = .default,
        session: URLSession = .shared,
        processRunner: any ProcessRunning = AsyncProcessRunner()
    ) {
        self.modelsDirectory = modelsDirectory
        self.fileManager = fileManager
        self.session = session
        self.processRunner = processRunner
    }

    public var isComplete: Bool {
        ModelArtifact.allCases.allSatisfy { isPresent($0) }
    }

    public func fetchMissing() -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    try await fetchMissing { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func fetchMissing(progress: @escaping @Sendable (Double) -> Void) async throws {
        HoverLog.beginModelSetup()
        defer { HoverLog.endModelSetup() }
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

        try await extractTarBzip2(tempArchive, into: modelsDirectory)

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

        let size =
            (try? fileManager.attributesOfItem(atPath: downloaded.path)[.size] as? NSNumber)?
            .int64Value ?? -1
        guard size == expectedSize else {
            throw ModelSetupError.verificationFailed(
                "Downloaded file failed the size check."
            )
        }

        let staged = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).staged")
        try fileManager.moveItem(at: downloaded, to: staged)
        defer {
            // A failed or cancelled install leaves the verified staged copy as
            // cleanup only; the previous destination remains untouched.
            try? fileManager.removeItem(at: staged)
        }

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fileManager.moveItem(at: staged, to: destination)
        }
    }

    private func extractTarBzip2(_ archive: URL, into directory: URL) async throws {
        let result: ProcessResult
        do {
            result = try await processRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-xjf", archive.path, "-C", directory.path]
            )
        } catch {
            throw ModelSetupError.fetchFailed("Could not extract the segmentation model archive.")
        }
        guard result.terminationStatus == 0 else {
            throw ModelSetupError.fetchFailed("Could not extract the segmentation model archive.")
        }
    }
}

/// Mutable byte counter shared with @Sendable progress callbacks.
private final class CompletedBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Int64

    init(_ value: Int64) { storedValue = value }

    var value: Int64 {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
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
        let taskBox = DownloadTaskBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.setFinish { result in
                    continuation.resume(with: result)
                }
                let task = tracked.downloadTask(with: remote)
                taskBox.start(task)
            }
        } onCancel: {
            taskBox.cancel()
        }
    }
}

private final class DownloadTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var cancelled = false

    func start(_ task: URLSessionDownloadTask) {
        lock.lock()
        self.task = task
        let shouldCancel = cancelled
        lock.unlock()
        shouldCancel ? task.cancel() : task.resume()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }
}

private final class ProgressDownloadDelegate: NSObject, URLSessionDownloadDelegate,
    @unchecked Sendable
{
    let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var finish: (@Sendable (Result<URL, Error>) -> Void)?
    private var finished = false

    init(progress: @escaping @Sendable (Int64) -> Void) {
        self.progress = progress
    }

    func setFinish(_ finish: @escaping @Sendable (Result<URL, Error>) -> Void) {
        lock.withLock { self.finish = finish }
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
            !(200...299).contains(http.statusCode)
        {
            complete(
                .failure(
                    ModelSetupError.fetchFailed(
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
            complete(
                .failure(
                    ModelSetupError.fetchFailed(
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
        let completion: (@Sendable (Result<URL, Error>) -> Void)? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            let completion = finish
            finish = nil
            return completion
        }
        completion?(result)
    }
}

// MARK: - Errors

public enum ModelSetupError: Error, LocalizedError {
    case fetchFailed(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fetchFailed(let message), .verificationFailed(let message):
            return message
        }
    }
}
