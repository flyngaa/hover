import Foundation

/// Cancellation-aware Foundation `Process` bridge shared by Whisper and
/// speaker diarization. `ProcessExecution` is the narrow synchronization
/// boundary around Foundation objects that are not themselves Sendable.
public struct AsyncProcessRunner: ProcessRunning {
    public var diagnosticLimit: Int

    public init(diagnosticLimit: Int = 256 * 1024) {
        self.diagnosticLimit = diagnosticLimit
    }

    public func run(executable: URL, arguments: [String]) async throws -> ProcessResult {
        let execution = ProcessExecution(
            executable: executable,
            arguments: arguments,
            outputLimit: diagnosticLimit
        )
        let result = try await withTaskCancellationHandler {
            try await execution.run()
        } onCancel: {
            execution.cancel()
        }
        try Task.checkCancellation()
        return result
    }
}

/// All mutable state is protected by `lock`; callbacks never expose the
/// Foundation process or pipes outside this object.
private final class ProcessExecution: @unchecked Sendable {
    private let executable: URL
    private let arguments: [String]
    private let outputLimit: Int
    private let lock = NSLock()

    private var process: Process?
    private var standardOutput = Data()
    private var standardError = Data()
    private var continuation: CheckedContinuation<ProcessResult, Error>?
    private var cancelled = false
    private var completed = false

    init(executable: URL, arguments: [String], outputLimit: Int) {
        self.executable = executable
        self.arguments = arguments
        self.outputLimit = outputLimit
    }

    func run() async throws -> ProcessResult {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr

            lock.lock()
            self.process = process
            self.continuation = continuation
            lock.unlock()

            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                self?.append(handle.availableData, toStandardError: false)
            }
            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                self?.append(handle.availableData, toStandardError: true)
            }
            process.terminationHandler = { [weak self] process in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                self?.append(
                    stdout.fileHandleForReading.readDataToEndOfFile(), toStandardError: false)
                self?.append(
                    stderr.fileHandleForReading.readDataToEndOfFile(), toStandardError: true)
                self?.finish(status: process.terminationStatus)
            }

            do {
                try process.run()
                lock.lock()
                let shouldCancel = cancelled
                lock.unlock()
                if shouldCancel { process.terminate() }
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                finish(throwing: error)
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = process
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    private func append(_ data: Data, toStandardError: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        if toStandardError {
            appendBounded(data, to: &standardError)
        } else {
            appendBounded(data, to: &standardOutput)
        }
        lock.unlock()
    }

    private func appendBounded(_ data: Data, to destination: inout Data) {
        guard destination.count < outputLimit else { return }
        destination.append(data.prefix(outputLimit - destination.count))
    }

    private func finish(status: Int32) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        let result = ProcessResult(
            terminationStatus: status,
            standardOutput: String(decoding: standardOutput, as: UTF8.self),
            standardError: String(decoding: standardError, as: UTF8.self)
        )
        lock.unlock()
        continuation?.resume(returning: result)
    }

    private func finish(throwing error: Error) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}
