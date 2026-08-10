import AVFoundation
import AppKit
import CoreGraphics
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

    /// macOS reports Screen Recording as a plain yes/no, so "never asked" is
    /// remembered here. Without it a first-time user would be sent to System
    /// Settings to switch on something they were never offered.
    public var screenRecording: PermissionState {
        if CGPreflightScreenCaptureAccess() { return .granted }
        return defaults.bool(forKey: Keys.screenRecordingRequested) ? .denied : .notRequested
    }

    public func requestMicrophone() async -> PermissionState {
        guard microphone == .notRequested else { return microphone }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        return microphone
    }

    public func requestScreenRecording() {
        // Recorded before the call, not after: the prompt is answered long after
        // this returns, and its return value is false either way.
        defaults.set(true, forKey: Keys.screenRecordingRequested)
        _ = CGRequestScreenCaptureAccess()
    }

    public func openSettings(for permission: RecordingPermission) {
        let pane: String
        switch permission {
        case .microphone: pane = "Privacy_Microphone"
        case .screenRecording: pane = "Privacy_ScreenCapture"
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
        static let screenRecordingRequested = "hasRequestedScreenRecording"
    }
}
