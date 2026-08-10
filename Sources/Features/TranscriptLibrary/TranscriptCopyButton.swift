import AppKit
import SwiftUI

struct TranscriptCopyButton: View {
    @Environment(RecordingModel.self) private var recording
    @Environment(TranscriptLibraryModel.self) private var library
    @State private var copied = false
    var iconOnly = false

    private var hasCopyableContent: Bool {
        !recording.committedText.isEmpty
            || recording.isRecording
            || !library.markedTranscriptIDs.isEmpty
    }

    var body: some View {
        Button(action: copyText) {
            if iconOnly {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            } else {
                Label(
                    copied ? "Copied" : "Copy",
                    systemImage: copied ? "checkmark" : "doc.on.doc"
                )
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!hasCopyableContent)
        .help("Copy transcript text")
    }

    private func copyText() {
        let text: String
        if !recording.committedText.isEmpty || recording.isRecording {
            text = recording.committedText
        } else if !library.markedTranscriptIDs.isEmpty {
            text = library.combinedMarkedContent()
        } else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
