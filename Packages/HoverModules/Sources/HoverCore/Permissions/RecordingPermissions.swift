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
}
