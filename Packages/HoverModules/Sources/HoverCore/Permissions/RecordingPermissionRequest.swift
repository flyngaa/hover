import Foundation

/// A question the user has to answer before a recording can start the way they
/// asked for it.
///
/// The engine publishes one of these instead of quietly recording something
/// other than what was asked for. It carries its own wording so the sheet that
/// shows it stays a dumb view and the copy can be tested.
public struct RecordingPermissionRequest: Equatable, Sendable {

    /// Identifies the recording command this question belongs to. Answers from
    /// an older sheet are ignored after another request has replaced it.
    public let id: UUID
    public let recordingRequestID: UUID

    /// What is standing in the way.
    public enum Reason: Equatable, Sendable {
        /// macOS has never asked about System Audio. Explain what it buys
        /// before triggering the system prompt, rather than after.
        case screenRecordingNotRequested
        /// System Audio was refused. Only System Settings can undo it.
        case screenRecordingRefused
        /// The prompt has been shown; macOS won't apply the grant until Hover
        /// launches again.
        case screenRecordingNeedsRelaunch
        /// The microphone was refused, so Hover can't hear the user at all.
        case microphoneRefused
    }

    public let reason: Reason

    /// What Hover could still record with, for a user who would rather get on
    /// with it than deal with System Settings now. `nil` when refusing leaves
    /// nothing worth recording.
    public let fallback: InputSource?

    public init(
        id: UUID = UUID(),
        recordingRequestID: UUID = UUID(),
        reason: Reason,
        fallback: InputSource?
    ) {
        self.id = id
        self.recordingRequestID = recordingRequestID
        self.reason = reason
        self.fallback = fallback
    }

    public var title: String {
        switch reason {
        case .screenRecordingNotRequested: return "Include system audio?"
        case .screenRecordingRefused: return "System audio access is off"
        case .screenRecordingNeedsRelaunch: return "Reopen Hover for system audio"
        case .microphoneRefused: return "Microphone is off"
        }
    }

    public var message: String {
        switch reason {
        case .screenRecordingNotRequested:
            return
                "To include audio from calls and videos, macOS requires System Audio Recording Only access. Hover captures audio samples only."
        case .screenRecordingRefused:
            return
                "Allow Hover under System Audio Recording Only in System Settings, then try again."
        case .screenRecordingNeedsRelaunch:
            return
                "System audio access is enabled. Reopen Hover, then try the recording again."
        case .microphoneRefused:
            return "Enable Hover in System Settings > Privacy & Security > Microphone."
        }
    }

    /// The button that moves the permission itself forward.
    public var primaryButton: String {
        switch reason {
        case .screenRecordingNotRequested: return "Allow"
        case .screenRecordingRefused, .microphoneRefused: return "Open Settings"
        case .screenRecordingNeedsRelaunch: return "Restart"
        }
    }

    /// The button that records anyway with what macOS already allows. Absent
    /// when there is no ``fallback``.
    public var fallbackButton: String? {
        switch fallback {
        case .microphone: return "Mic only"
        case .system: return "System audio only"
        case .both, nil: return nil
        }
    }

    /// One-line version for Agent Mode, which has no way to show a dialog: what
    /// is missing and where to fix it, on a single stderr line.
    public var consoleSummary: String {
        switch reason {
        case .screenRecordingNotRequested, .screenRecordingNeedsRelaunch:
            return
                "System Audio Recording Only access is needed. Allow Hover in System Settings, then reopen it."
        case .screenRecordingRefused:
            return
                "System audio access is off. Enable Hover under System Audio Recording Only in System Settings."
        case .microphoneRefused:
            return "Microphone is off. System Settings > Privacy & Security > Microphone."
        }
    }

    /// The same question, moved on to the restart that macOS requires before a
    /// fresh System Audio grant reaches Hover.
    public func awaitingRelaunch() -> RecordingPermissionRequest {
        RecordingPermissionRequest(
            id: id,
            recordingRequestID: recordingRequestID,
            reason: .screenRecordingNeedsRelaunch,
            fallback: fallback
        )
    }
}
