import Foundation
import Testing
@testable import HoverApp

@Suite struct InstallCLITests {
    private let commandURL = URL(fileURLWithPath: "/usr/local/bin/hover")
    private let wrapperURL = URL(
        fileURLWithPath: "/Applications/Hover.app/Contents/Resources/hover"
    )
    private let executableURL = URL(
        fileURLWithPath: "/Applications/Hover.app/Contents/MacOS/Hover"
    )

    @Test func absentCommandIsNotInstalled() {
        #expect(makeInstallCLI(fileSystem: FakeInstallCLIFileSystem()).status() == .notInstalled)
    }

    @Test func symlinkToCurrentBundledWrapperIsInstalled() {
        let fileSystem = FakeInstallCLIFileSystem(
            entries: [commandURL: .symbolicLink, wrapperURL: .regularFile],
            symlinkDestinations: [commandURL: wrapperURL],
            executableURLs: [commandURL, wrapperURL, executableURL]
        )

        #expect(makeInstallCLI(fileSystem: fileSystem).status() == .installed)
    }

    @Test func wrapperForMovedAppNeedsRepair() {
        let previousWrapper = URL(
            fileURLWithPath: "/Users/me/Downloads/Hover.app/Contents/Resources/hover"
        )
        let fileSystem = FakeInstallCLIFileSystem(
            entries: [commandURL: .symbolicLink, previousWrapper: .regularFile],
            symlinkDestinations: [commandURL: previousWrapper],
            executableURLs: [commandURL, previousWrapper, wrapperURL, executableURL]
        )

        #expect(makeInstallCLI(fileSystem: fileSystem).status() == .needsRepair)
    }

    @Test func missingWrapperOrExecutableNeedsRepair() {
        let missingWrapper = FakeInstallCLIFileSystem(
            entries: [commandURL: .symbolicLink],
            symlinkDestinations: [commandURL: wrapperURL],
            executableURLs: [commandURL, executableURL]
        )
        let missingExecutable = FakeInstallCLIFileSystem(
            entries: [commandURL: .symbolicLink, wrapperURL: .regularFile],
            symlinkDestinations: [commandURL: wrapperURL],
            executableURLs: [commandURL, wrapperURL]
        )

        #expect(makeInstallCLI(fileSystem: missingWrapper).status() == .needsRepair)
        #expect(makeInstallCLI(fileSystem: missingExecutable).status() == .needsRepair)
    }

    @Test func bareMachOSymlinkNeedsRepairButForeignEntriesAreNotClaimed() {
        let bareMachOSymlink = FakeInstallCLIFileSystem(
            entries: [commandURL: .symbolicLink],
            symlinkDestinations: [commandURL: executableURL]
        )
        let foreignSymlink = FakeInstallCLIFileSystem(
            entries: [commandURL: .symbolicLink],
            symlinkDestinations: [commandURL: URL(fileURLWithPath: "/usr/local/bin/other-hover")]
        )
        let foreignFile = FakeInstallCLIFileSystem(
            entries: [commandURL: .regularFile]
        )

        #expect(makeInstallCLI(fileSystem: bareMachOSymlink).status() == .needsRepair)
        #expect(makeInstallCLI(fileSystem: foreignSymlink).status() == .foreign)
        #expect(makeInstallCLI(fileSystem: foreignFile).status() == .foreign)
    }

    @Test func installAlwaysRewritesToTheCurrentBundledWrapper() async throws {
        let installCLI = makeInstallCLI(fileSystem: FakeInstallCLIFileSystem(
            entries: [commandURL: .symbolicLink, wrapperURL: .regularFile],
            symlinkDestinations: [commandURL: wrapperURL],
            executableURLs: [commandURL, wrapperURL, executableURL]
        ))
        let installer = FakeCLIWrapperInstaller()

        try await installCLI.install(using: installer)

        #expect(installer.installs == [.init(wrapper: wrapperURL, destination: commandURL)])
    }

    @Test @MainActor func failedApprovalStaysUninstalledAndCanRetry() async {
        let installer = FakeCLIWrapperInstaller(error: FakeInstallError.cancelled)
        let controller = InstallCLIController(
            installCLI: makeInstallCLI(fileSystem: FakeInstallCLIFileSystem(
                entries: [wrapperURL: .regularFile],
                executableURLs: [wrapperURL, executableURL]
            )),
            installer: installer
        )

        await controller.install()

        #expect(controller.status == .notInstalled)
        #expect(controller.errorMessage == "Install CLI needs administrator approval. Try again.")
        #expect(!controller.isInstalling)

        installer.error = nil
        await controller.install()

        #expect(controller.errorMessage == nil)
        #expect(installer.installs == [.init(wrapper: wrapperURL, destination: commandURL)])
        #expect(!controller.isInstalling)
    }

    private func makeInstallCLI(fileSystem: some InstallCLIFileSystem) -> InstallCLI {
        InstallCLI(
            commandURL: commandURL,
            bundledWrapperURL: wrapperURL,
            executableURL: executableURL,
            fileSystem: fileSystem
        )
    }
}

private struct FakeInstallCLIFileSystem: InstallCLIFileSystem {
    var entries: [URL: InstallCLIFileEntry] = [:]
    var symlinkDestinations: [URL: URL] = [:]
    var executableURLs: Set<URL> = []

    func entry(at url: URL) -> InstallCLIFileEntry { entries[url] ?? .missing }
    func symbolicLinkDestination(at url: URL) -> URL? { symlinkDestinations[url] }
    func isExecutableFile(at url: URL) -> Bool { executableURLs.contains(url) }
}

private enum FakeInstallError: Error {
    case cancelled
}

private final class FakeCLIWrapperInstaller: CLIWrapperInstalling {
    struct Install: Equatable {
        let wrapper: URL
        let destination: URL
    }

    private(set) var installs: [Install] = []
    var error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func install(wrapperAt wrapper: URL, at destination: URL) async throws {
        if let error { throw error }
        installs.append(.init(wrapper: wrapper, destination: destination))
    }
}
