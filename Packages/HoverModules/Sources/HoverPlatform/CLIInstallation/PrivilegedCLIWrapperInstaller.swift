import Foundation

public struct PrivilegedCLIWrapperInstaller: CLIWrapperInstalling {
    public init() {}

    public func install(wrapperAt wrapper: URL, at destination: URL) async throws {
        let destinationDirectory = destination.deletingLastPathComponent()
        let shellCommand = [
            "/bin/mkdir -p \(Self.shellQuote(destinationDirectory.path))",
            "/bin/rm -f \(Self.shellQuote(destination.path))",
            "/bin/ln -s \(Self.shellQuote(wrapper.path)) \(Self.shellQuote(destination.path))",
        ].joined(separator: " && ")
        let appleScriptCommand =
            shellCommand
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
