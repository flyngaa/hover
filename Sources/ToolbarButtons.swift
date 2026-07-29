import SwiftUI

/// Shared pill styling for the top-bar controls so their contents get
/// consistent padding and never look squashed.
struct ToolbarPill: ViewModifier {
    var filled = false

    func body(content: Content) -> some View {
        content
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(filled ? 0.16 : 0.09))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
            .contentShape(Capsule(style: .continuous))
            .fixedSize()
    }
}

extension View {
    func toolbarPill(filled: Bool = false) -> some View {
        modifier(ToolbarPill(filled: filled))
    }
}

struct InputMenu: View {
    @Environment(TranscriberEngine.self) private var engine

    var body: some View {
        Menu {
            ForEach(InputSource.allCases) { source in
                Button {
                    engine.inputSource = source
                } label: {
                    if engine.inputSource == source {
                        Label(source.label, systemImage: "checkmark")
                    } else {
                        Text(source.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "waveform")
                    .foregroundStyle(.white)
                Text(engine.inputSource.label)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .toolbarPill()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(.primary)
        .disabled(engine.isRecording)
        .help("Which audio to transcribe")
    }
}

struct CopyButton: View {
    @Environment(TranscriberEngine.self) private var engine
    @State private var copied = false
    var iconOnly = false

    /// Cheap check for the disabled state — no file I/O in body.
    private var hasCopyableContent: Bool {
        !engine.committedText.isEmpty || engine.isRecording || !engine.markedTranscriptIDs.isEmpty
    }

    var body: some View {
        Button(action: copyText) {
            if iconOnly {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            } else {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!hasCopyableContent)
        .help("Copy transcript text")
    }

    private func copyText() {
        // File reads happen here, on click — never during body evaluation.
        let text: String
        if !engine.committedText.isEmpty || engine.isRecording {
            text = engine.liveDisplayText
        } else if !engine.markedTranscriptIDs.isEmpty {
            text = engine.combinedMarkedContent()
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

struct RecordButton: View {
    @Environment(TranscriberEngine.self) private var engine

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Circle()
                    .fill(engine.isRecording ? Color.red : Color.red.opacity(0.7))
                    .frame(width: 9, height: 9)
                Text(engine.isRecording ? "Stop" : "Record")
                    .fontWeight(.medium)
            }
            .toolbarPill(filled: true)
        }
        .buttonStyle(.plain)
        .alert("Something went wrong", isPresented: .init(
            get: { engine.authError != nil },
            set: { if !$0 { engine.authError = nil } }
        )) {
            Button("OK") { engine.authError = nil }
        } message: {
            Text(engine.authError ?? "")
        }
    }

    private func toggle() {
        if engine.isRecording {
            engine.stopRecording()
        } else {
            engine.clearMarkedTranscripts()
            engine.lastRecordingTranscript = nil
            Task { await engine.startRecording() }
        }
    }
}
