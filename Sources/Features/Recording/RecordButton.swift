import SwiftUI

struct RecordButton: View {
    @Environment(AppModel.self) private var appModel
    @Environment(RecordingModel.self) private var recording

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Circle()
                    .fill(recording.canStopRecording ? Color.red : Color.red.opacity(0.7))
                    .frame(width: 9, height: 9)
                Text(buttonTitle)
                    .fontWeight(.medium)
            }
            .toolbarPill(filled: true)
        }
        .buttonStyle(.plain)
        .alert(
            "Something went wrong",
            isPresented: .init(
                get: { appModel.presentedAlert != nil || recording.presentedFailureMessage != nil },
                set: { if !$0 { appModel.dismissAlert() } }
            )
        ) {
            Button("OK") { appModel.dismissAlert() }
        } message: {
            Text(appModel.presentedAlert?.message ?? recording.presentedFailureMessage ?? "")
        }
        .disabled(recording.isFinalizingRecording)
    }

    private var buttonTitle: String {
        if recording.canStopRecording { return "Stop" }
        if recording.isFinalizingRecording { return "Processing…" }
        return "Record"
    }

    private func toggle() {
        if recording.canStopRecording {
            Task { await appModel.stopRecording() }
        } else {
            Task { await appModel.startRecording() }
        }
    }
}
