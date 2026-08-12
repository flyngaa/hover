public enum RecordingPermission: Sendable {
    case microphone
    case screenRecording
}

public enum PermissionState: Sendable {
    case granted
    case notRequested
    case denied
}

@MainActor
public protocol RecordingPermissions: AnyObject {
    var microphone: PermissionState { get }
    var screenRecording: PermissionState { get }
    func requestMicrophone() async -> PermissionState
    func requestScreenRecording()
    func openSettings(for permission: RecordingPermission)
    func relaunch()

    /// Remember what the last system-audio capture attempt observed.
    ///
    /// Core Audio has no public preflight API, so Hover learns whether System
    /// Audio Recording Only is allowed by trying to start the tap — and stores
    /// the result so the next Record can ask before capturing.
    func noteScreenRecordingAccess(_ state: PermissionState)
}
