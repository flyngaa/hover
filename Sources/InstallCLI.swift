import Foundation

enum InstallCLIStatus: Equatable {
    case notInstalled
    case installed
    case needsRepair
    case foreign
}

enum InstallCLIFileEntry {
    case missing
    case regularFile
    case symbolicLink
    case other
}

protocol InstallCLIFileSystem {
    func entry(at url: URL) -> InstallCLIFileEntry
    func symbolicLinkDestination(at url: URL) -> URL?
    func isExecutableFile(at url: URL) -> Bool
}

protocol CLIWrapperInstalling {
    func install(wrapperAt wrapper: URL, at destination: URL) async throws
}

struct SystemInstallCLIFileSystem: InstallCLIFileSystem {
    private let fileManager = FileManager.default

    func entry(at url: URL) -> InstallCLIFileEntry {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType
        else { return .missing }

        switch type {
        case .typeSymbolicLink: return .symbolicLink
        case .typeRegular: return .regularFile
        default: return .other
        }
    }

    func symbolicLinkDestination(at url: URL) -> URL? {
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path)
        else { return nil }
        if destination.hasPrefix("/") {
            return URL(fileURLWithPath: destination).standardizedFileURL
        }
        return url.deletingLastPathComponent()
            .appendingPathComponent(destination)
            .standardizedFileURL
    }

    func isExecutableFile(at url: URL) -> Bool {
        fileManager.isExecutableFile(atPath: url.path)
    }
}

enum InstallCLIError: LocalizedError {
    case unavailableBundleAsset
    case privilegeRequestFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailableBundleAsset:
            return "Hover couldn't find its bundled command wrapper."
        case .privilegeRequestFailed(let message):
            return message
        }
    }
}

/// Performs the single privileged filesystem operation behind Install CLI.
/// Both the UI and the Homebrew cask link the same signed, in-bundle wrapper;
/// neither links directly onto the Mach-O in Contents/MacOS.
struct PrivilegedCLIWrapperInstaller: CLIWrapperInstalling {
    func install(wrapperAt wrapper: URL, at destination: URL) async throws {
        let destinationDirectory = destination.deletingLastPathComponent()
        let shellCommand = [
            "/bin/mkdir -p \(Self.shellQuote(destinationDirectory.path))",
            "/bin/rm -f \(Self.shellQuote(destination.path))",
            "/bin/ln -s \(Self.shellQuote(wrapper.path)) \(Self.shellQuote(destination.path))",
        ].joined(separator: " && ")
        let appleScriptCommand = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \"\(appleScriptCommand)\" with administrator privileges",
        ]
        process.standardError = standardError

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else {
            let data = standardError.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw InstallCLIError.privilegeRequestFailed(
                detail.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "Administrator approval was not granted."
            )
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct InstallCLI {
    let commandURL: URL
    let bundledWrapperURL: URL
    let executableURL: URL
    let fileSystem: any InstallCLIFileSystem

    static func live(bundle: Bundle = .main) throws -> InstallCLI {
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

    func install(using installer: any CLIWrapperInstalling) async throws {
        guard fileSystem.isExecutableFile(at: bundledWrapperURL),
              fileSystem.isExecutableFile(at: executableURL)
        else { throw InstallCLIError.unavailableBundleAsset }
        try await installer.install(wrapperAt: bundledWrapperURL, at: commandURL)
    }

    func status() -> InstallCLIStatus {
        switch fileSystem.entry(at: commandURL) {
        case .missing:
            return .notInstalled
        case .regularFile, .other:
            return .foreign
        case .symbolicLink:
            guard let linkedURL = fileSystem.symbolicLinkDestination(at: commandURL)
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
