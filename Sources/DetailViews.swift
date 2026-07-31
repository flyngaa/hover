import SwiftUI

struct LiveView: View {
    @Environment(TranscriberEngine.self) private var engine

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(engine.committedText)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    // While the recording is being processed after Stop (e.g.
                    // speaker tagging), sweep a bright band across the text.
                    .wipeShimmer(active: engine.isProcessing)
                    .id("transcript")
            }
            .onChange(of: engine.committedText) {
                proxy.scrollTo("transcript", anchor: .bottom)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .topTrailing) {
            CopyButton(iconOnly: true)
                .padding(12)
        }
        .overlay(alignment: .bottom) {
            if engine.isRecording {
                HStack {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text(engine.statusMessage)
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

struct SavedView: View {
    @Environment(TranscriberEngine.self) private var engine
    let transcript: SavedTranscript
    /// Loaded in `.task` — file I/O must not run during body evaluation.
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
            CopyButton(iconOnly: true)
                .padding(12)
        }
        .task(id: transcript.id) {
            content = engine.loadTranscriptContent(transcript)
        }
    }
}

struct MarkedTranscriptsView: View {
    @Environment(TranscriberEngine.self) private var engine
    /// Loaded in `.task` — combines several files, must not run in body.
    @State private var combined = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(engine.markedTranscriptIDs.count) transcripts marked")
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
            CopyButton(iconOnly: true)
                .padding(12)
        }
        .task(id: engine.markedTranscriptIDs) {
            combined = engine.combinedMarkedContent()
        }
    }
}

/// A "processing" effect: dims the content and sweeps a bright white band across
/// it, masked to the content's shape, until `active` turns off. Used for the
/// in-progress recording (sidebar) and the transcript text while it's being
/// tagged after Stop. White band — deliberately not the brand red/orange.
struct WipeShimmer: ViewModifier {
    var active: Bool
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .opacity(active ? 0.35 : 1)
            .overlay {
                if active {
                    GeometryReader { geo in
                        let w = geo.size.width
                        let band = max(w * 0.5, 60)
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .white, location: 0.5),
                                .init(color: .clear, location: 1.0),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: band)
                        // Sweep from just off the left edge to off the right.
                        .offset(x: -band + phase * (w + band))
                    }
                    .mask(content)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
                }
            }
            .onAppear { if active { start() } }
            .onChange(of: active) { _, now in
                if now { start() } else { phase = 0 }
            }
    }

    private func start() {
        phase = 0
        withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
            phase = 1
        }
    }
}

extension View {
    func wipeShimmer(active: Bool) -> some View {
        modifier(WipeShimmer(active: active))
    }
}
