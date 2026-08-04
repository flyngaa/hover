import AVFoundation
import AppKit
import CoreGraphics

/// One of the two things macOS has to allow before Hover can hear.
enum RecordingPermission {
    case microphone
    /// What macOS files system-audio capture under, since the same API can also
    /// see the screen. Hover only ever reads the audio.
    case screenRecording
}

/// Where macOS stands on one of them.
enum PermissionState {
    case granted
    /// Never asked. macOS shows its own prompt the first time Hover asks.
    case notRequested
    /// Asked and refused, or turned off again later. Only System Settings
    /// undoes it — asking a second time does nothing.
    case denied
}

/// What macOS allows Hover to hear, and how to ask for more.
///
/// The seam that lets the engine settle permissions *before* a recording starts
/// instead of discovering them halfway through: production reads the real
/// system state, tests supply canned answers.
protocol RecordingPermissions: AnyObject {
    var microphone: PermissionState { get }
    var screenRecording: PermissionState { get }

    /// Show the macOS microphone prompt if it hasn't been shown before, and
    /// report where that leaves us. The answer applies immediately.
    func requestMicrophone() async -> PermissionState

    /// Show the macOS Screen Recording prompt. Unlike the microphone, a grant
    /// never reaches the running process — macOS only applies it to the next
    /// launch, which is why callers have to offer a relaunch afterwards.
    func requestScreenRecording()

    /// Open the System Settings pane where a refused permission can be turned
    /// back on.
    func openSettings(for permission: RecordingPermission)

    /// Quit and start again, so a Screen Recording grant takes effect.
    func relaunch()
}

/// ``RecordingPermissions`` backed by the real system state.
final class SystemRecordingPermissions: RecordingPermissions {

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var microphone: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notRequested
        // Restricted (parental controls, MDM) is a dead end for the user in the
        // same way a refusal is, and there is nothing more Hover can ask for.
        default: return .denied
        }
    }

    /// macOS reports Screen Recording as a plain yes/no, so "never asked" is
    /// remembered here. Without it a first-time user would be sent to System
    /// Settings to switch on something they were never offered.
    var screenRecording: PermissionState {
        if CGPreflightScreenCaptureAccess() { return .granted }
        return defaults.bool(forKey: Keys.screenRecordingRequested) ? .denied : .notRequested
    }

    func requestMicrophone() async -> PermissionState {
        guard microphone == .notRequested else { return microphone }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        return microphone
    }

    func requestScreenRecording() {
        // Recorded before the call, not after: the prompt is answered long after
        // this returns, and its return value is false either way.
        defaults.set(true, forKey: Keys.screenRecordingRequested)
        _ = CGRequestScreenCaptureAccess()
    }

    func openSettings(for permission: RecordingPermission) {
        let pane: String
        switch permission {
        case .microphone: pane = "Privacy_Microphone"
        case .screenRecording: pane = "Privacy_ScreenCapture"
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        // Without this macOS just reactivates the copy that is still quitting.
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private enum Keys {
        static let screenRecordingRequested = "hasRequestedScreenRecording"
    }
}
