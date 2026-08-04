import Foundation

/// A question the user has to answer before a recording can start the way they
/// asked for it.
///
/// The engine publishes one of these instead of quietly recording something
/// other than what was asked for. It carries its own wording so the sheet that
/// shows it stays a dumb view and the copy can be tested.
struct RecordingPermissionRequest: Equatable {

    /// What is standing in the way.
    enum Reason: Equatable {
        /// macOS has never asked about Screen Recording. Explain what it buys
        /// before triggering the system prompt, rather than after.
        case screenRecordingNotRequested
        /// Screen Recording was refused. Only System Settings can undo it.
        case screenRecordingRefused
        /// The prompt has been shown; macOS won't apply the grant until Hover
        /// launches again.
        case screenRecordingNeedsRelaunch
        /// The microphone was refused, so Hover can't hear the user at all.
        case microphoneRefused
    }

    let reason: Reason

    /// What Hover could still record with, for a user who would rather get on
    /// with it than deal with System Settings now. `nil` when refusing leaves
    /// nothing worth recording.
    let fallback: InputSource?

    var title: String {
        switch reason {
        case .screenRecordingNotRequested: return "Include system audio?"
        case .screenRecordingRefused: return "Screen Recording is off"
        case .screenRecordingNeedsRelaunch: return "Restart required"
        case .microphoneRefused: return "Microphone is off"
        }
    }

    var message: String {
        switch reason {
        case .screenRecordingNotRequested:
            return "Needed to capture what your Mac is playing (calls, videos). macOS lists this under Screen Recording. Hover only uses the audio."
        case .screenRecordingRefused:
            return "Enable Hover in System Settings > Privacy & Security > Screen Recording, then restart."
        case .screenRecordingNeedsRelaunch:
            return "macOS only applies Screen Recording after a restart."
        case .microphoneRefused:
            return "Enable Hover in System Settings > Privacy & Security > Microphone."
        }
    }

    /// The button that moves the permission itself forward.
    var primaryButton: String {
        switch reason {
        case .screenRecordingNotRequested: return "Allow"
        case .screenRecordingRefused, .microphoneRefused: return "Open Settings"
        case .screenRecordingNeedsRelaunch: return "Restart"
        }
    }

    /// The button that records anyway with what macOS already allows. Absent
    /// when there is no ``fallback``.
    var fallbackButton: String? {
        switch fallback {
        case .microphone: return "Mic only"
        case .system: return "System audio only"
        case .both, nil: return nil
        }
    }

    /// One-line version for Agent Mode, which has no way to show a dialog: what
    /// is missing and where to fix it, on a single stderr line.
    var consoleSummary: String {
        switch reason {
        case .screenRecordingNotRequested, .screenRecordingNeedsRelaunch:
            return "Screen Recording permission needed. Open Hover once to allow it."
        case .screenRecordingRefused:
            return "Screen Recording is off. System Settings > Privacy & Security > Screen Recording."
        case .microphoneRefused:
            return "Microphone is off. System Settings > Privacy & Security > Microphone."
        }
    }

    /// The same question, moved on to the restart that macOS requires before a
    /// fresh Screen Recording grant reaches Hover.
    func awaitingRelaunch() -> RecordingPermissionRequest {
        RecordingPermissionRequest(reason: .screenRecordingNeedsRelaunch, fallback: fallback)
    }
}
