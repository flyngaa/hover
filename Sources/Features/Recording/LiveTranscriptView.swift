import SwiftUI

struct LiveTranscriptView: View {
    @Environment(RecordingModel.self) private var recording

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(recording.committedText)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .wipeShimmer(active: recording.isProcessing)
                    .id("transcript")
            }
            .onChange(of: recording.committedText) {
                proxy.scrollTo("transcript", anchor: .bottom)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .topTrailing) {
            TranscriptCopyButton(iconOnly: true)
                .padding(12)
        }
        .overlay(alignment: .bottom) {
            if recording.isRecording {
                HStack {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text(recording.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 12)
            }
        }
    }
}
