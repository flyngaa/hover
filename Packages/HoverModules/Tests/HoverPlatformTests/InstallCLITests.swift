import Foundation
import HoverCore
import Testing

@testable import HoverPlatform

@Suite @MainActor struct InstallCLITests {
    private let commandURL = URL(fileURLWithPath: "/usr/local/bin/hover")
    private let wrapperURL = URL(
        fileURLWithPath: "/Applications/Hover.app/Contents/Resources/hover"
    )
    private let executableURL = URL(
        fileURLWithPath: "/Applications/Hover.app/Contents/MacOS/Hover"
    )

    @Test func absentCommandIsNotInstalled() throws {
        #expect(
            try makeInstallCLI(fileSystem: FakeInstallCLIFileSystem()).status() == .notInstalled)
    }

    @Test func symlinkToCurrentBundledWrapperIsInstalled() throws {
        let fileSystem = FakeInstallCLIFileSystem(
            entries: [commandURL: .symbolicLink, wrapperURL: .regularFile],
            symlinkDestinations: [commandURL: wrapperURL],
            executableURLs: [commandURL, wrapperURL, executableURL]
        )

        #expect(try makeInstallCLI(fileSystem: fileSystem).status() == .installed)
    }

    @Test func wrapperForMovedAppNeedsRepair() throws {
        let previousWrapper = URL(
            fileURLWithPath: "/Users/me/Downloads/Hover.app/Contents/Resources/hover"
        )
        let fileSystem = FakeInstallCLIFileSystem(
            entries: [commandURL: .symbolicLink, previousWrapper: .regularFile],
            symlinkDestinations: [commandURL: previousWrapper],
            executableURLs: [commandURL, previousWrapper, wrapperURL, executableURL]
        )

        #expect(try makeInstallCLI(fileSystem: fileSystem).status() == .needsRepair)
    }

    @Test func missingWrapperOrExecutableNeedsRepair() throws {
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

        #expect(try makeInstallCLI(fileSystem: missingWrapper).status() == .needsRepair)
        #expect(try makeInstallCLI(fileSystem: missingExecutable).status() == .needsRepair)
    }

    @Test func bareMachOSymlinkNeedsRepairButForeignEntriesAreNotClaimed() throws {
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

        #expect(try makeInstallCLI(fileSystem: bareMachOSymlink).status() == .needsRepair)
        #expect(try makeInstallCLI(fileSystem: foreignSymlink).status() == .foreign)
        #expect(try makeInstallCLI(fileSystem: foreignFile).status() == .foreign)
    }

    @Test func installAlwaysRewritesToTheCurrentBundledWrapper() async throws {
        let installCLI = makeInstallCLI(
            fileSystem: FakeInstallCLIFileSystem(
                entries: [commandURL: .symbolicLink, wrapperURL: .regularFile],
                symlinkDestinations: [commandURL: wrapperURL],
                executableURLs: [commandURL, wrapperURL, executableURL]
            ))
        let installer = FakeCLIWrapperInstaller()

        try await installCLI.install(using: installer)

        #expect(installer.installs == [.init(wrapper: wrapperURL, destination: commandURL)])
    }

    @Test func unreadableCommandIsNotReportedAsAbsent() {
        #expect(throws: InstallCLIError.self) {
            try makeInstallCLI(fileSystem: UnreadableInstallCLIFileSystem()).status()
        }
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

private struct UnreadableInstallCLIFileSystem: InstallCLIFileSystem {
    func entry(at url: URL) throws -> InstallCLIFileEntry {
        throw InstallCLIError.statusReadFailed("simulated")
    }

    func symbolicLinkDestination(at url: URL) throws -> URL? { nil }
    func isExecutableFile(at url: URL) -> Bool { false }
}

private struct FakeInstallCLIFileSystem: InstallCLIFileSystem {
    var entries: [URL: InstallCLIFileEntry] = [:]
    var symlinkDestinations: [URL: URL] = [:]
    var executableURLs: Set<URL> = []

    func entry(at url: URL) -> InstallCLIFileEntry { entries[url] ?? .missing }
    func symbolicLinkDestination(at url: URL) -> URL? { symlinkDestinations[url] }
    func isExecutableFile(at url: URL) -> Bool { executableURLs.contains(url) }
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
