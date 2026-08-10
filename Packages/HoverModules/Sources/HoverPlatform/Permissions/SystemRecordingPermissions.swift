import AVFoundation
import AppKit
import HoverCore

/// ``RecordingPermissions`` backed by the real system state.
public final class SystemRecordingPermissions: RecordingPermissions {

    public init() {}

    public var microphone: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notRequested
        // Restricted (parental controls, MDM) is a dead end for the user in the
        // same way a refusal is, and there is nothing more Hover can ask for.
        default: return .denied
        }
    }

    /// Core Audio doesn't expose a preflight API for its audio-only privacy
    /// permission. The first AudioDeviceStart for a process tap is the request:
    /// macOS shows its own prompt and applies the answer to that call.
    public var screenRecording: PermissionState {
        .granted
    }

    public func requestMicrophone() async -> PermissionState {
        guard microphone == .notRequested else { return microphone }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        return microphone
    }

    public func requestScreenRecording() {
        // Audio-only access is requested by starting the Core Audio process tap.
    }

    public func openSettings(for permission: RecordingPermission) {
        let pane: String
        switch permission {
        case .microphone: pane = "Privacy_Microphone"
        case .screenRecording: pane = "Privacy_AudioCapture"
        }
        guard
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    public func relaunch() {
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
}
