import Foundation
import HoverPlatform
import Testing

@testable import HoverApp

@Suite @MainActor struct InstallCLIControllerTests {
    @Test func failedApprovalStaysUninstalledAndCanRetry() async {
        let command = URL(fileURLWithPath: "/usr/local/bin/hover")
        let wrapper = URL(fileURLWithPath: "/Applications/Hover.app/Contents/Resources/hover")
        let executable = URL(fileURLWithPath: "/Applications/Hover.app/Contents/MacOS/Hover")
        let installer = ControllerFakeInstaller(error: ControllerFakeError.cancelled)
        let controller = InstallCLIController(
            installCLI: InstallCLI(
                commandURL: command,
                bundledWrapperURL: wrapper,
                executableURL: executable,
                fileSystem: ControllerFakeFileSystem(executableURLs: [wrapper, executable])
            ),
            installer: installer
        )

        await controller.install()

        #expect(controller.status == .notInstalled)
        #expect(controller.errorMessage == ControllerFakeError.cancelled.localizedDescription)
        #expect(!controller.isInstalling)

        installer.error = nil
        await controller.install()

        #expect(controller.errorMessage == nil)
        #expect(installer.installs == [.init(wrapper: wrapper, destination: command)])
        #expect(!controller.isInstalling)
    }
}

private struct ControllerFakeFileSystem: InstallCLIFileSystem {
    let executableURLs: Set<URL>

    func entry(at url: URL) -> InstallCLIFileEntry { .missing }
    func symbolicLinkDestination(at url: URL) -> URL? { nil }
    func isExecutableFile(at url: URL) -> Bool { executableURLs.contains(url) }
}

private enum ControllerFakeError: Error { case cancelled }

private final class ControllerFakeInstaller: CLIWrapperInstalling {
    struct Install: Equatable {
        let wrapper: URL
        let destination: URL
    }

    private(set) var installs: [Install] = []
    var error: Error?

    init(error: Error? = nil) { self.error = error }

    func install(wrapperAt wrapper: URL, at destination: URL) async throws {
        if let error { throw error }
        installs.append(.init(wrapper: wrapper, destination: destination))
    }
}
