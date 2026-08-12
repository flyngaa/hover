import HoverCore
import SwiftUI

struct SidebarView: View {
    @Environment(RecordingModel.self) private var recording
    @Environment(TranscriptLibraryModel.self) private var library
    @State private var searchText = ""
    /// IDs matching the current search, computed off the render path.
    /// nil = no active filter. Content search reads every transcript file,
    /// so it runs debounced in a task — never during body evaluation.
    @State private var searchHits: Set<String>?
    @State private var renameTarget: SavedTranscript?
    @State private var renameText = ""
    @State private var newGroupTarget: SavedTranscript?
    @State private var newGroupName = ""
    @State private var confirmDeleteMarked = false

    private var filtered: [SavedTranscript] {
        guard let searchHits else { return library.savedTranscripts }
        return library.savedTranscripts.filter { searchHits.contains($0.id) }
    }

    private var orderedVisibleIDs: [String] {
        var ids: [String] = []
        ids += filtered.filter { $0.group == nil }.map(\.id)
        for group in library.groups {
            ids += filtered.filter { $0.group == group }.map(\.id)
        }
        return ids
    }

    var body: some View {
        @Bindable var library = library
        List(selection: $library.markedTranscriptIDs) {
            let rootItems = filtered.filter { $0.group == nil }
            Section("Transcripts") {
                if let title = recording.recordingTitle {
                    InProgressRow(title: title)
                }
                if library.savedTranscripts.isEmpty {
                    if recording.recordingTitle == nil {
                        Text("No transcripts yet")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                } else {
                    ForEach(rootItems) { t in
                        row(t)
                    }
                }
            }

            ForEach(library.groups, id: \.self) { group in
                let items = filtered.filter { $0.group == group }
                if searchHits == nil || !items.isEmpty {
                    Section(group) {
                        ForEach(items) { t in
                            row(t)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("")
        .tint(BrandColors.orange)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search transcripts")
        .task(id: searchText) {
            // Debounced, off-render search. Content matching reads every
            // transcript file, so it must never run inside `body`.
            let query = searchText.trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else {
                searchHits = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let hits = await library.searchHits(for: query)
            guard !Task.isCancelled else { return }
            searchHits = hits
        }
        .onChange(of: library.markedTranscriptIDs) { _, ids in
            if ids.count == 1 {
                library.selectionAnchorID = ids.first
            }
        }
        .background(shortcutButtons)
        .alert(
            "Rename Transcript",
            isPresented: .init(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let t = renameTarget { library.rename(t, to: renameText) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .alert(
            "New Group",
            isPresented: .init(
                get: { newGroupTarget != nil },
                set: { if !$0 { newGroupTarget = nil } }
            )
        ) {
            TextField("Group name", text: $newGroupName)
            Button("Create & Move") {
                if let t = newGroupTarget { library.move(t, toGroup: newGroupName) }
                newGroupTarget = nil
            }
            Button("Cancel", role: .cancel) { newGroupTarget = nil }
        }
        .alert("Delete marked transcripts?", isPresented: $confirmDeleteMarked) {
            Button("Delete", role: .destructive) {
                library.deleteMarkedTranscripts()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete \(library.markedTranscriptIDs.count) files.")
        }
    }

    @ViewBuilder
    private func row(_ t: SavedTranscript) -> some View {
        Text(t.name)
            .lineLimit(1)
            .padding(.vertical, 2)
            .tag(t.id)
            .contextMenu {
                Button(library.markedTranscriptIDs.contains(t.id) ? "Unmark" : "Mark") {
                    library.toggleMark(t.id)
                }
                Button("Rename…") {
                    renameText = t.name
                    renameTarget = t
                }
                .disabled(library.markedTranscriptIDs.count > 1)
                Menu("Move to") {
                    Button("Transcripts") { library.move(t, toGroup: nil) }
                        .disabled(t.group == nil)
                    if !library.groups.isEmpty { Divider() }
                    ForEach(library.groups, id: \.self) { group in
                        Button(group) { library.move(t, toGroup: group) }
                            .disabled(t.group == group)
                    }
                    Divider()
                    Button("New Group…") {
                        newGroupName = ""
                        newGroupTarget = t
                    }
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(t.path.path, inFileViewerRootedAtPath: "")
                }
                Divider()
                if library.markedTranscriptIDs.count > 1 {
                    Button("Delete \(library.markedTranscriptIDs.count) Marked", role: .destructive)
                    {
                        confirmDeleteMarked = true
                    }
                } else {
                    Button("Delete", role: .destructive) {
                        library.deleteTranscript(t)
                    }
                }
            }
    }

    private var shortcutButtons: some View {
        Group {
            Button("Mark All") {
                library.markAll(ids: orderedVisibleIDs)
            }
            .keyboardShortcut("a", modifiers: .command)

            Button("Clear Marks") {
                library.clearMarkedTranscripts()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])

            Button("Toggle Mark") {
                toggleFocusedMark()
            }
            .keyboardShortcut(.space, modifiers: [])

            Button("Extend Mark Up") {
                extendMark(direction: -1)
            }
            .keyboardShortcut(.upArrow, modifiers: .shift)

            Button("Extend Mark Down") {
                extendMark(direction: 1)
            }
            .keyboardShortcut(.downArrow, modifiers: .shift)

            Button("Delete Marked") {
                guard !library.markedTranscriptIDs.isEmpty else { return }
                confirmDeleteMarked = true
            }
            .keyboardShortcut(.delete, modifiers: [])
        }
        .hidden()
        .frame(width: 0, height: 0)
    }

    private func toggleFocusedMark() {
        let ids = orderedVisibleIDs
        guard !ids.isEmpty else { return }

        if let anchor = library.selectionAnchorID, ids.contains(anchor) {
            library.toggleMark(anchor)
            return
        }

        if let marked = library.markedTranscriptIDs.first, ids.contains(marked) {
            library.toggleMark(marked)
            return
        }

        library.toggleMark(ids[0])
    }

    private func extendMark(direction: Int) {
        let ids = orderedVisibleIDs
        guard !ids.isEmpty else { return }

        let currentIndex: Int
        if let anchor = library.selectionAnchorID, let index = ids.firstIndex(of: anchor) {
            currentIndex = index
        } else if let marked = library.markedTranscriptIDs.first,
            let index = ids.firstIndex(of: marked)
        {
            currentIndex = index
        } else {
            library.markRange(to: ids[0], in: ids)
            return
        }

        let nextIndex = max(0, min(ids.count - 1, currentIndex + direction))
        library.markRange(to: ids[nextIndex], in: ids)
    }
}

/// The sidebar row for the recording currently in progress. A highlight band
/// sweeps across the name (a "gradient wipe") to signal that it's still being
/// worked on, until the finished transcript replaces it.
private struct InProgressRow: View {
    let title: String

    var body: some View {
        Text(title)
            .lineLimit(1)
            .padding(.vertical, 2)
            .wipeShimmer(active: true)
            .allowsHitTesting(false)
            .help("Recording in progress…")
    }
}
