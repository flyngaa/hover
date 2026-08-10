import SwiftUI

struct MarkedTranscriptsView: View {
    @Environment(TranscriptLibraryModel.self) private var library
    @State private var combined = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(library.markedTranscriptIDs.count) transcripts marked")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 8)

            Divider()

            ScrollView {
                Text(combined)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .topTrailing) {
            TranscriptCopyButton(iconOnly: true)
                .padding(12)
        }
        .task(id: library.markedTranscriptIDs) {
            combined = library.combinedMarkedContent()
        }
    }
}
