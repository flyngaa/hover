import SwiftUI

struct ContentView: View {
    @Environment(TranscriberEngine.self) private var engine

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    OutputOptionsButton()
                    InputMenu()
                    RecordButton()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                detailPane
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        .tint(BrandColors.orange)
        .background(HideWindowTitle())
    }

    @ViewBuilder
    private var detailPane: some View {
        Group {
            if engine.isRecording || !engine.committedText.isEmpty {
                LiveView()
            } else if engine.markedTranscriptIDs.count > 1 {
                MarkedTranscriptsView()
            } else if let t = engine.primaryMarkedTranscript {
                SavedView(transcript: t)
            } else {
                EmptyDetailView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
