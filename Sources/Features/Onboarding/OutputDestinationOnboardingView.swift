import AppKit
import HoverCore
import SwiftUI

/// First-run prompt that asks where transcripts should be saved instead of
/// silently defaulting to `~/Documents/Transcripts`. Any detected Obsidian
/// vault is offered alongside the standard folder, and the choice is persisted
/// so the prompt only appears once. It can always be changed later from the
/// toolbar's Output Destination button.
struct OutputDestinationOnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TranscriptLibraryModel.self) private var library

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "folder")
                .font(.system(size: 34))
                .foregroundStyle(BrandColors.orange)

            VStack(spacing: 8) {
                Text("Where should Hover save transcripts?")
                    .font(.title2.weight(.semibold))
                Text(
                    "Transcripts are saved as Markdown in one folder. Pick an Obsidian vault "
                        + "or any folder — you can change this any time from the toolbar."
                )
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(nonVaultDestinations) { destinationRow($0) }
                ForEach(vaultDestinations) { destinationRow($0) }
            }
            .frame(maxWidth: 400)

            Button("Choose Another Folder…", action: chooseFolder)
                .buttonStyle(.bordered)
        }
        .padding(32)
        .frame(minWidth: 480, minHeight: 340)
        // The only way out is picking a destination; the standard folder is a
        // one-click default, so this asks once rather than saving silently.
        .interactiveDismissDisabled()
    }

    private var nonVaultDestinations: [OutputDestination] {
        library.outputDestinations.filter { $0.kind != .vault }
    }

    private var vaultDestinations: [OutputDestination] {
        library.outputDestinations.filter { $0.kind == .vault }
    }

    private func destinationRow(_ destination: OutputDestination) -> some View {
        let isVault = destination.kind == .vault
        return Button {
            choose(destination.directory)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isVault ? "books.vertical" : "folder")
                    .foregroundStyle(BrandColors.orange)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(destination.name)
                        .foregroundStyle(.primary)
                    Text(
                        isVault
                            ? "Obsidian vault"
                            : TranscriptLibraryModel.shortPath(destination.directory)
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func choose(_ url: URL) {
        library.setOutputDirectory(url)
        dismiss()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where Hover saves your transcript files."
        panel.directoryURL = library.outputDirectory

        guard panel.runModal() == .OK, let url = panel.url else { return }
        choose(url)
    }
}
