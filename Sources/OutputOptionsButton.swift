import SwiftUI

/// Picks the one folder transcripts are saved to. Obsidian vaults appear as
/// ordinary choices in the list — choosing one means transcripts live there,
/// not that a copy gets sent there.
struct OutputOptionsButton: View {
    @Environment(TranscriberEngine.self) private var engine

    var body: some View {
        Menu {
            let destinations = engine.outputDestinations
            let current = engine.currentOutputDestination

            Section("Save transcripts to") {
                ForEach(destinations.filter { $0.kind != .vault }) { destination in
                    destinationButton(destination, isCurrent: destination.id == current.id)
                }
            }

            let vaults = destinations.filter { $0.kind == .vault }
            if !vaults.isEmpty {
                Section("Obsidian vaults") {
                    ForEach(vaults) { destination in
                        destinationButton(destination, isCurrent: destination.id == current.id)
                    }
                }
            }

            Divider()

            Button("Choose Folder…") { chooseFolder() }
                .disabled(engine.isRecording)

            Button("Show Folder in Finder") { engine.revealOutputDirectory() }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: engine.currentOutputDestination.kind == .vault
                      ? "circle.hexagongrid.fill" : "folder")
                    .foregroundStyle(.white)
                Text(engine.currentOutputDestination.name)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .toolbarPill()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(.primary)
        .help("Where transcripts are saved: \(engine.outputDirectoryLabel)")
        .confirmationDialog(
            moveTitle,
            isPresented: .init(
                get: { engine.pendingOutputChange != nil },
                set: { if !$0 { engine.cancelPendingOutputChange() } }
            ),
            titleVisibility: .visible,
            presenting: engine.pendingOutputChange
        ) { pending in
            Button("Move \(pending.transcriptCount == 1 ? "Transcript" : "Transcripts")") {
                engine.resolvePendingOutputChange(movingTranscripts: true)
            }
            Button("Leave Them") {
                engine.resolvePendingOutputChange(movingTranscripts: false)
            }
            Button("Cancel", role: .cancel) {
                engine.cancelPendingOutputChange()
            }
        } message: { pending in
            Text(moveMessage(pending))
        }
    }

    @ViewBuilder
    private func destinationButton(_ destination: OutputDestination, isCurrent: Bool) -> some View {
        Button {
            engine.requestOutputChange(to: destination)
        } label: {
            if isCurrent {
                Label(destination.name, systemImage: "checkmark")
            } else {
                Text(destination.name)
            }
        }
        .disabled(engine.isRecording)
    }

    // MARK: - Move confirmation

    private var moveTitle: String {
        guard let pending = engine.pendingOutputChange else { return "" }
        let noun = pending.transcriptCount == 1 ? "transcript" : "transcripts"
        return "Move your \(noun) to \(pending.destination.name)?"
    }

    private func moveMessage(_ pending: PendingOutputChange) -> String {
        let count = pending.transcriptCount
        let noun = count == 1 ? "transcript" : "transcripts"
        return """
        You have \(count) \(noun) in \(TranscriberEngine.shortPath(pending.origin)).

        Move them and they follow you to the new folder. Leave them and they stay \
        where they are — they'll drop out of the list until you switch back.
        """
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where Hover saves your transcript files."
        panel.directoryURL = engine.outputDirectory

        guard panel.runModal() == .OK, let url = panel.url else { return }
        engine.requestOutputChange(toFolder: url)
    }
}
