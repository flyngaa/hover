import Foundation
import HoverCore
import Testing

@testable import HoverPlatform

@Suite struct ProcessRunnerTests {
    @Test func capturesBothStreamsAndExitStatus() async throws {
        let result = try await AsyncProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf output; printf diagnostic >&2; exit 7"]
        )

        #expect(result.terminationStatus == 7)
        #expect(result.standardOutput == "output")
        #expect(result.standardError == "diagnostic")
    }

    @Test func cancellationTerminatesTheChild() async {
        let started = ContinuousClock.now
        let task = Task {
            try await AsyncProcessRunner().run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"]
            )
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected process cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(ContinuousClock.now - started < .seconds(2))
    }
}
