import AVFoundation
import AppKit
import HoverCore

/// ``RecordingPermissions`` backed by the real system state.
public final class SystemRecordingPermissions: RecordingPermissions {

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var microphone: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notRequested
        // Restricted (parental controls, MDM) is a dead end for the user in the
        // same way a refusal is, and there is nothing more Hover can ask for.
        default: return .denied
        }
    }

    /// A refused process tap still runs — it just delivers silence — so the
    /// answer has to come from the privacy database rather than from whether
    /// capture started. ``SystemAudioAccess`` reads the same service macOS
    /// gates the tap on; the remembered outcome of the last attempt is the
    /// fallback for when that lookup isn't available.
    public var screenRecording: PermissionState {
        if let state = SystemAudioAccess.current { return state }
        switch defaults.string(forKey: Keys.systemAudioAccess) {
        case "denied": return .denied
        default: return .granted
        }
    }

    public func requestMicrophone() async -> PermissionState {
        guard microphone == .notRequested else { return microphone }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        return microphone
    }

    public func requestScreenRecording() {
        // Falls back to the Core Audio process tap raising the prompt itself.
        SystemAudioAccess.request()
    }

    public func noteScreenRecordingAccess(_ state: PermissionState) {
        switch state {
        case .granted:
            defaults.set("granted", forKey: Keys.systemAudioAccess)
        case .denied:
            defaults.set("denied", forKey: Keys.systemAudioAccess)
        case .notRequested:
            defaults.removeObject(forKey: Keys.systemAudioAccess)
        }
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

    private enum Keys {
        static let systemAudioAccess = "systemAudioRecordingAccess"
    }
}
