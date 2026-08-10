import HoverCore
import SwiftUI

/// Asks for a permission Hover needs *before* triggering macOS's own prompt, so
/// the user knows what they're being asked for and can still record with what
/// is already allowed. Shown in place of starting a recording.
///
/// Reads the question from the engine rather than taking it as a parameter: one
/// answer leads to the next question (allowing System Audio can lead to the
/// restart macOS requires), and this way the open sheet just changes its wording
/// instead of having to close and reopen. All of it comes from
/// ``RecordingPermissionRequest``.
struct PermissionRequestSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(RecordingModel.self) private var recording

    var body: some View {
        if let request = recording.permissionRequest {
            VStack(alignment: .leading, spacing: 16) {
                Text(request.title)
                    .font(.system(size: 16, weight: .semibold))

                Text(request.message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button("Cancel") {
                        recording.dismissPermissionRequest(requestID: request.id)
                    }
                    .keyboardShortcut(.cancelAction)

                    Spacer(minLength: 12)

                    if let fallbackButton = request.fallbackButton {
                        Button(fallbackButton) {
                            Task { await appModel.recordWithReducedInput(requestID: request.id) }
                        }
                    }

                    Button(request.primaryButton) {
                        recording.grantPermission(requestID: request.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BrandColors.orange)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 440)
        }
    }
}
