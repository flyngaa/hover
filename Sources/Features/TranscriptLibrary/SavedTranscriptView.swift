import HoverCore
import SwiftUI

struct SavedTranscriptView: View {
    @Environment(TranscriptLibraryModel.self) private var library
    let transcript: SavedTranscript
    @State private var content = ""

    var body: some View {
        ScrollView {
            Text(content)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .topTrailing) {
            TranscriptCopyButton(iconOnly: true)
                .padding(12)
        }
        .task(id: transcript.id) {
            content = library.loadTranscriptContent(transcript)
        }
    }
}
