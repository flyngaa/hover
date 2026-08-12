import Foundation

public enum InstallCLIStatus: Equatable {
    case notInstalled
    case installed
    case needsRepair
    case foreign
}

public enum InstallCLIFileEntry {
    case missing
    case regularFile
    case symbolicLink
    case other
}

public protocol InstallCLIFileSystem {
    func entry(at url: URL) throws -> InstallCLIFileEntry
    func symbolicLinkDestination(at url: URL) throws -> URL?
    func isExecutableFile(at url: URL) -> Bool
}

@MainActor
public protocol CLIWrapperInstalling {
    func install(wrapperAt wrapper: URL, at destination: URL) async throws
}

public enum InstallCLIError: LocalizedError {
    case unavailableBundleAsset
    case privilegeRequestFailed(String)
    case statusReadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailableBundleAsset:
            return "Hover couldn't find its bundled command wrapper."
        case .privilegeRequestFailed(let message):
            return message
        case .statusReadFailed:
            return
                "Hover couldn't inspect the installed command. Check its permissions and try again."
        }
    }
}

public struct InstallCLI {
    public let commandURL: URL
    public let bundledWrapperURL: URL
    public let executableURL: URL
    public let fileSystem: any InstallCLIFileSystem

    public init(
        commandURL: URL,
        bundledWrapperURL: URL,
        executableURL: URL,
        fileSystem: any InstallCLIFileSystem
    ) {
        self.commandURL = commandURL
        self.bundledWrapperURL = bundledWrapperURL
        self.executableURL = executableURL
        self.fileSystem = fileSystem
    }

    public static func live(bundle: Bundle = .main) throws -> InstallCLI {
        guard let executableURL = bundle.executableURL,
            let resourcesURL = bundle.resourceURL
        else { throw InstallCLIError.unavailableBundleAsset }
        return InstallCLI(
            commandURL: URL(fileURLWithPath: "/usr/local/bin/hover"),
            bundledWrapperURL: resourcesURL.appendingPathComponent("hover"),
            executableURL: executableURL,
            fileSystem: SystemInstallCLIFileSystem()
        )
    }

    @MainActor
    public func install(using installer: any CLIWrapperInstalling) async throws {
        guard fileSystem.isExecutableFile(at: bundledWrapperURL),
            fileSystem.isExecutableFile(at: executableURL)
        else { throw InstallCLIError.unavailableBundleAsset }
        try await installer.install(wrapperAt: bundledWrapperURL, at: commandURL)
    }

    public func status() throws -> InstallCLIStatus {
        switch try fileSystem.entry(at: commandURL) {
        case .missing:
            return .notInstalled
        case .regularFile, .other:
            return .foreign
        case .symbolicLink:
            guard let linkedURL = try fileSystem.symbolicLinkDestination(at: commandURL)
            else { return .foreign }
            if linkedURL == bundledWrapperURL {
                return fileSystem.isExecutableFile(at: bundledWrapperURL)
                    && fileSystem.isExecutableFile(at: executableURL)
                    ? .installed
                    : .needsRepair
            }
            if Self.isHoverBundledWrapper(linkedURL) || Self.isHoverExecutable(linkedURL) {
                return .needsRepair
            }
            return .foreign
        }
    }

    private static func isHoverBundledWrapper(_ url: URL) -> Bool {
        let resourcesDirectory = url.deletingLastPathComponent()
        let contentsDirectory = resourcesDirectory.deletingLastPathComponent()
        let appDirectory = contentsDirectory.deletingLastPathComponent()
        return url.lastPathComponent == "hover"
            && resourcesDirectory.lastPathComponent == "Resources"
            && contentsDirectory.lastPathComponent == "Contents"
            && appDirectory.lastPathComponent.caseInsensitiveCompare("Hover.app") == .orderedSame
    }

    private static func isHoverExecutable(_ url: URL) -> Bool {
        let macOSDirectory = url.deletingLastPathComponent()
        let contentsDirectory = macOSDirectory.deletingLastPathComponent()
        let appDirectory = contentsDirectory.deletingLastPathComponent()
        return !url.lastPathComponent.isEmpty
            && macOSDirectory.lastPathComponent == "MacOS"
            && contentsDirectory.lastPathComponent == "Contents"
            && appDirectory.lastPathComponent.caseInsensitiveCompare("Hover.app") == .orderedSame
    }
}
