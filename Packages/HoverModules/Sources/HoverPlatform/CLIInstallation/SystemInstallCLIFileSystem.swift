import Foundation

public struct SystemInstallCLIFileSystem: InstallCLIFileSystem {
    private let fileManager = FileManager.default

    public init() {}

    public func entry(at url: URL) throws -> InstallCLIFileEntry {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return .missing
        } catch {
            throw InstallCLIError.statusReadFailed(error.localizedDescription)
        }
        guard let type = attributes[.type] as? FileAttributeType else {
            throw InstallCLIError.statusReadFailed("The command entry has no file type.")
        }

        switch type {
        case .typeSymbolicLink: return .symbolicLink
        case .typeRegular: return .regularFile
        default: return .other
        }
    }

    public func symbolicLinkDestination(at url: URL) throws -> URL? {
        let destination: String
        do {
            destination = try fileManager.destinationOfSymbolicLink(atPath: url.path)
        } catch {
            throw InstallCLIError.statusReadFailed(error.localizedDescription)
        }
        if destination.hasPrefix("/") {
            return URL(fileURLWithPath: destination).standardizedFileURL
        }
        return url.deletingLastPathComponent()
            .appendingPathComponent(destination)
            .standardizedFileURL
    }

    public func isExecutableFile(at url: URL) -> Bool {
        fileManager.isExecutableFile(atPath: url.path)
    }
}
