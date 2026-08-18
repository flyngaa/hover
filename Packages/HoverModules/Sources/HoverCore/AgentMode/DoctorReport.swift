import Foundation

/// A read-only readiness report: everything that must be true before
/// `hover record` can capture and save a transcript, gathered in one place so an
/// agent or a human can see what is missing without starting a recording.
///
/// Pure value logic — the platform gathers the facts (architecture, permissions,
/// model data, PATH install, output folder) and hands them here for formatting.
/// See the `doctor` route in ``HoverCLI`` for the gathering side. Keeping the
/// shape here means the exit code, the text, and the JSON all agree and can be
/// unit-tested without a machine in any particular state.
public struct DoctorReport: Equatable, Sendable, Encodable {

    /// How a single precondition came out. `warn` is for things that don't stop
    /// a recording (e.g. `hover` isn't symlinked onto PATH) but are worth
    /// surfacing; only `fail` makes the report non-ready.
    public enum Status: String, Equatable, Sendable, Encodable {
        case ok
        case warn
        case fail
    }

    /// One precondition and what to do about it.
    public struct Check: Equatable, Sendable, Encodable {
        /// Stable machine key for agents to match on (e.g. `microphone`).
        public let id: String
        /// Human-readable label for the text report.
        public let name: String
        public let status: Status
        public let detail: String
        /// What to do about it when the status is not `ok`; `nil` when there is
        /// nothing to fix.
        public let fix: String?

        public init(
            id: String,
            name: String,
            status: Status,
            detail: String,
            fix: String? = nil
        ) {
            self.id = id
            self.name = name
            self.status = status
            self.detail = detail
            self.fix = fix
        }
    }

    public let checks: [Check]

    public init(checks: [Check]) {
        self.checks = checks
    }

    /// `true` when nothing is marked `fail`; warnings do not make Hover unready.
    public var isReady: Bool {
        !checks.contains { $0.status == .fail }
    }

    /// Non-zero when any check failed, so a script can gate on `hover doctor`.
    public var exitCode: Int32 {
        isReady ? 0 : 1
    }

    /// Plain-text rendering for a human at a terminal.
    public var textReport: String {
        var lines = ["Hover doctor", ""]
        for check in checks {
            lines.append("  [\(check.status.rawValue)] \(check.name): \(check.detail)")
            if let fix = check.fix, check.status != .ok {
                lines.append("        Fix: \(fix)")
            }
        }
        lines.append("")
        lines.append(
            isReady
                ? "Hover is ready to record."
                : "Hover is not ready to record. Fix the items marked [fail] above."
        )
        return lines.joined(separator: "\n")
    }

    /// JSON rendering for scripts and agents. Stable keys: `ready` and `checks`
    /// (each with `id`, `name`, `status`, `detail`, `fix`).
    public func jsonReport() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw DoctorReportError.encodingFailed
        }
        return string
    }

    private enum CodingKeys: String, CodingKey {
        case ready
        case checks
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isReady, forKey: .ready)
        try container.encode(checks, forKey: .checks)
    }
}

public enum DoctorReportError: Error, Equatable, Sendable {
    case encodingFailed
}
