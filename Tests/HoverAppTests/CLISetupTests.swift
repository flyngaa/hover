import Foundation
import HoverCore
import HoverPlatform
import Testing

@testable import HoverApp

@Suite @MainActor struct CLISetupTests {

    @Test func setupFetchesOnlyWhenModelDataIsMissing() {
        #expect(HoverCLI.setupAction(isComplete: false, statusOnly: false) == .fetch)

        let ready = HoverCLI.setupAction(isComplete: true, statusOnly: false)
        #expect(
            ready
                == .finish(
                    .init(
                        exitCode: 0,
                        standardError: "Model data is ready.\n"
                    )))
    }

    @Test func statusReportsMissingWithoutFetching() {
        let missing = HoverCLI.setupAction(isComplete: false, statusOnly: true)
        #expect(
            missing
                == .finish(
                    .init(
                        exitCode: 1,
                        standardError:
                            "Model data is missing. Run `hover setup` to download about 575 MB.\n"
                    )))
    }

    @Test func successfulAndFailedFetchesHaveStableProcessContracts() {
        #expect(
            HoverCLI.setupCompletion(isComplete: true, errorDescription: nil)
                == .init(
                    exitCode: 0,
                    standardError: "Model data is ready.\n"
                ))
        #expect(
            HoverCLI.setupCompletion(isComplete: false, errorDescription: "Network dropped.")
                == .init(
                    exitCode: 1,
                    standardError: "Model Setup failed: Network dropped.\n"
                ))
    }

    @Test func routedSetupFetchesAndWritesOnlyToStandardError() async {
        let setup = FakeModelSetup(isComplete: false)
        let output = OutputCapture()

        let exitCode = await HoverCLI.executeSetup(
            CLIOptions.parse(["setup"]),
            modelSetup: setup,
            output: output.streams
        )

        #expect(exitCode == 0)
        #expect(setup.fetchCount == 1)
        #expect(output.standardOutput.isEmpty)
        #expect(output.standardError.contains("Model Setup: 50%"))
        #expect(output.standardError.hasSuffix("Model data is ready.\n"))
    }

    @Test func routedStatusNeverFetchesAndInvalidSetupFails() async {
        let setup = FakeModelSetup(isComplete: false)
        let statusOutput = OutputCapture()

        let statusExit = await HoverCLI.executeSetup(
            CLIOptions.parse(["setup", "--status"]),
            modelSetup: setup,
            output: statusOutput.streams
        )

        #expect(statusExit == 1)
        #expect(setup.fetchCount == 0)
        #expect(statusOutput.standardOutput.isEmpty)
        #expect(statusOutput.standardError.contains("Model data is missing"))

        let invalidOutput = OutputCapture()
        let invalidExit = await HoverCLI.executeSetup(
            CLIOptions.parse(["setup", "--force"]),
            modelSetup: setup,
            output: invalidOutput.streams
        )
        #expect(invalidExit == 1)
        #expect(invalidOutput.standardOutput.isEmpty)
        #expect(invalidOutput.standardError.contains("Unsupported setup option"))
    }
}

private final class OutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = ""
    private var stderr = ""

    var streams: CLIOutput {
        CLIOutput(
            standardOutput: { [weak self] text in self?.append(text, toStandardError: false) },
            standardError: { [weak self] text in self?.append(text, toStandardError: true) }
        )
    }

    var standardOutput: String { locked { stdout } }
    var standardError: String { locked { stderr } }

    private func append(_ text: String, toStandardError: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if toStandardError { stderr += text } else { stdout += text }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
