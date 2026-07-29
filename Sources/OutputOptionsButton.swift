import SwiftUI

/// Picks the one folder transcripts are saved to. Obsidian vaults appear as
/// ordinary choices in the list — choosing one means transcripts live there,
/// not that a copy gets sent there.
///
/// A popover rather than a `Menu`: a macOS menu row holds a title and one
/// leading icon, and every row here also carries its own button for opening
/// that folder in Finder.
struct OutputOptionsButton: View {
    @Environment(TranscriberEngine.self) private var engine
    @State private var isShowingDestinations = false

    var body: some View {
        Button {
            isShowingDestinations.toggle()
        } label: {
            HStack(spacing: 7) {
                destinationIcon(engine.currentOutputDestination)
                    .foregroundStyle(.white)
                Text(engine.currentOutputDestination.name)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .toolbarPill()
        }
        .buttonStyle(.plain)
        .help("Where transcripts are saved: \(engine.outputDirectoryLabel)")
        .popover(isPresented: $isShowingDestinations, arrowEdge: .bottom) {
            destinationList
        }
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

    // MARK: - The list of folders

    private var destinationList: some View {
        let destinations = engine.outputDestinations
        let current = engine.currentOutputDestination

        return VStack(alignment: .leading, spacing: 1) {
            Text("Save transcripts to")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 3)

            // Plain folders first, vaults after — one list, one choice.
            ForEach(destinations.filter { $0.kind != .vault }) { destination in
                row(destination, isCurrent: destination.id == current.id)
            }
            ForEach(destinations.filter { $0.kind == .vault }) { destination in
                row(destination, isCurrent: destination.id == current.id)
            }

            Divider().padding(.vertical, 5)

            DestinationRow(
                title: "Choose Folder…",
                isEnabled: !engine.isRecording,
                select: chooseFolder
            )
        }
        .padding(.bottom, 7)
        .frame(width: 270)
    }

    private func row(_ destination: OutputDestination, isCurrent: Bool) -> DestinationRow {
        DestinationRow(
            title: destination.name,
            tag: destination.kind == .vault ? "Obsidian vault" : nil,
            showsObsidianIcon: destination.kind == .vault,
            isCurrent: isCurrent,
            isEnabled: !engine.isRecording,
            select: { select(destination) },
            reveal: { engine.reveal(destination.directory) }
        )
    }

    // MARK: - Actions

    private func select(_ destination: OutputDestination) {
        isShowingDestinations = false
        // Wait for the popover to go: raising the move confirmation while it's
        // still on screen can lose the dialog, leaving the switch half-done.
        DispatchQueue.main.async {
            engine.requestOutputChange(to: destination)
        }
    }

    private func chooseFolder() {
        isShowingDestinations = false
        DispatchQueue.main.async {
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

    // MARK: - Toolbar icon

    /// Obsidian's own mark for a vault, a plain folder for anything else.
    @ViewBuilder
    private func destinationIcon(_ destination: OutputDestination) -> some View {
        if destination.kind != .vault {
            Image(systemName: "folder")
        } else {
            ObsidianMarkIcon()
        }
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
}

/// One line of the folder list: click the row to save there, or the folder
/// button on the right to open that folder in Finder. `reveal` is nil for rows
/// that aren't a folder yet, like "Choose Folder…".
private struct DestinationRow: View {
    let title: String
    var tag: String?
    var showsObsidianIcon = false
    var isCurrent = false
    var isEnabled = true
    let select: () -> Void
    var reveal: (() -> Void)?

    @State private var isHoveringRow = false
    @State private var isHoveringReveal = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                // Kept in the layout when unticked so the titles line up.
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(isCurrent ? 1 : 0)
                    .frame(width: 12, alignment: .leading)

                if showsObsidianIcon {
                    ObsidianMarkIcon(height: 12)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }

                Text(title)
                if let tag {
                    Text("(\(tag))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
            }
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onTapGesture { if isEnabled { select() } }

            if let reveal {
                Button(action: reveal) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(isHoveringReveal ? .primary : .secondary)
                        .frame(width: 24, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHoveringReveal = $0 }
                .help("Show \(title) in Finder")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(isHoveringRow && isEnabled ? 0.1 : 0))
        )
        .padding(.horizontal, 6)
        .onHover { isHoveringRow = $0 }
    }
}

/// Obsidian's logo, loaded once from the bundled SVG. Template so callers can
/// tint it like an SF Symbol.
private struct ObsidianMarkIcon: View {
    var height: CGFloat = 13

    var body: some View {
        if let mark = Self.image {
            Image(nsImage: mark)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: height)
        } else {
            // build.sh treats artwork as optional, so leave a stand-in rather
            // than a hole if the asset didn't make it in.
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: height))
        }
    }

    private static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "Obsidian", withExtension: "svg"),
              let mark = NSImage(contentsOf: url)
        else { return nil }
        mark.isTemplate = true
        return mark
    }()
}
